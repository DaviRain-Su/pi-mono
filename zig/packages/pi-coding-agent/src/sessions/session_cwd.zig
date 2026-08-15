const std = @import("std");
const session_manager_mod = @import("session_manager.zig");

/// Detected mismatch between a session's stored cwd and the filesystem.
/// Mirrors `packages/coding-agent/src/core/session-cwd.ts`.
pub const MissingSessionCwdIssue = struct {
    /// Optional path to the session file the stored cwd came from. When
    /// non-null, callers and diagnostics can reference the session that
    /// triggered the issue.
    session_file: ?[]const u8,
    /// The stored cwd that no longer exists on disk.
    session_cwd: []const u8,
    /// Replacement cwd to use when the user agrees to continue.
    fallback_cwd: []const u8,
};

/// Owned snapshot of a `MissingSessionCwdIssue` that survives independently
/// of any session manager / session manager bytes. Used by lifecycle
/// preflight callers and the interactive bootstrap so the diagnostic can be
/// surfaced after the producing context has been torn down.
pub const OwnedMissingSessionCwdIssue = struct {
    session_file: ?[]u8,
    session_cwd: []u8,
    fallback_cwd: []u8,

    pub fn deinit(self: *OwnedMissingSessionCwdIssue, allocator: std.mem.Allocator) void {
        if (self.session_file) |path| allocator.free(path);
        allocator.free(self.session_cwd);
        allocator.free(self.fallback_cwd);
        self.* = undefined;
    }

    pub fn issue(self: *const OwnedMissingSessionCwdIssue) MissingSessionCwdIssue {
        return .{
            .session_file = self.session_file,
            .session_cwd = self.session_cwd,
            .fallback_cwd = self.fallback_cwd,
        };
    }
};

/// Captures `issue` into an owned snapshot. Caller must call
/// `OwnedMissingSessionCwdIssue.deinit`.
pub fn captureOwnedMissingSessionCwdIssue(
    allocator: std.mem.Allocator,
    issue: MissingSessionCwdIssue,
) !OwnedMissingSessionCwdIssue {
    const session_file_copy: ?[]u8 = if (issue.session_file) |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (session_file_copy) |path| allocator.free(path);
    const session_cwd_copy = try allocator.dupe(u8, issue.session_cwd);
    errdefer allocator.free(session_cwd_copy);
    const fallback_cwd_copy = try allocator.dupe(u8, issue.fallback_cwd);
    return .{
        .session_file = session_file_copy,
        .session_cwd = session_cwd_copy,
        .fallback_cwd = fallback_cwd_copy,
    };
}

/// Reads only the JSONL header of `session_file` and returns an owned
/// missing-cwd issue when the stored cwd does not exist on disk. Returns
/// null if the stored cwd is empty, the stored cwd still exists, or the
/// header cannot be parsed (callers fall through to the heavier session
/// manager path which produces the standard error in that case).
///
/// Designed to run BEFORE provider/auth resolution and tool construction so
/// missing-cwd diagnostics always preempt unrelated bootstrap failures.
pub fn preflightMissingSessionCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_file: []const u8,
    fallback_cwd: []const u8,
) !?OwnedMissingSessionCwdIssue {
    var header = session_manager_mod.readSessionHeader(allocator, io, session_file) catch |err| switch (err) {
        // Defer to the heavier session manager path for missing/corrupt files;
        // those failures already produce deterministic diagnostics later.
        error.FileNotFound, error.InvalidSessionFile => return null,
        else => return err,
    };
    defer session_manager_mod.freeSessionHeader(allocator, &header);

    if (header.cwd.len == 0) return null;
    if (pathExists(io, header.cwd)) return null;

    const issue = MissingSessionCwdIssue{
        .session_file = session_file,
        .session_cwd = header.cwd,
        .fallback_cwd = fallback_cwd,
    };
    return try captureOwnedMissingSessionCwdIssue(allocator, issue);
}

/// Returns a `MissingSessionCwdIssue` if the session manager has a persisted
/// session file with a stored cwd that does not exist. In every other case the
/// caller can proceed normally.
///
/// Matches TypeScript `getMissingSessionCwdIssue` semantics:
/// - Sessions without a session file (in-memory only) never report an issue.
/// - Empty stored cwds are treated as "nothing to validate".
/// - Existing stored cwds (file or directory) never report an issue.
pub fn getMissingSessionCwdIssue(
    io: std.Io,
    manager: *const session_manager_mod.SessionManager,
    fallback_cwd: []const u8,
) ?MissingSessionCwdIssue {
    const session_file = manager.getSessionFile() orelse return null;
    const session_cwd = manager.getCwd();
    if (session_cwd.len == 0) return null;
    if (pathExists(io, session_cwd)) return null;
    return .{
        .session_file = session_file,
        .session_cwd = session_cwd,
        .fallback_cwd = fallback_cwd,
    };
}

/// Returns true when `path` resolves to an existing filesystem entry (file or
/// directory). Matches Node's `fs.existsSync` for our purposes.
pub fn pathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        if (std.Io.Dir.openDirAbsolute(io, path, .{})) |dir| {
            var d = dir;
            d.close(io);
            return true;
        } else |_| {}
        if (std.Io.Dir.statFile(.cwd(), io, path, .{})) |_| {
            return true;
        } else |_| {}
        return false;
    }
    if (std.Io.Dir.openDir(.cwd(), io, path, .{})) |dir| {
        var d = dir;
        d.close(io);
        return true;
    } else |_| {}
    if (std.Io.Dir.statFile(.cwd(), io, path, .{})) |_| {
        return true;
    } else |_| {}
    return false;
}

/// Builds a deterministic non-interactive diagnostic for a missing session cwd.
/// Caller owns the returned slice. Matches TS `formatMissingSessionCwdError`.
pub fn formatMissingSessionCwdError(
    allocator: std.mem.Allocator,
    issue: MissingSessionCwdIssue,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("Stored session working directory does not exist: {s}", .{issue.session_cwd});
    if (issue.session_file) |file| {
        try out.writer.print("\nSession file: {s}", .{file});
    }
    try out.writer.print("\nCurrent working directory: {s}", .{issue.fallback_cwd});
    return allocator.dupe(u8, out.written());
}

/// Builds the deterministic continue/cancel prompt body. Matches TS
/// `formatMissingSessionCwdPrompt`.
pub fn formatMissingSessionCwdPrompt(
    allocator: std.mem.Allocator,
    issue: MissingSessionCwdIssue,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "cwd from session file does not exist\n{s}\n\ncontinue in current cwd\n{s}",
        .{ issue.session_cwd, issue.fallback_cwd },
    );
}

test "getMissingSessionCwdIssue returns null for in-memory sessions" {
    const allocator = std.testing.allocator;
    var manager = try session_manager_mod.SessionManager.inMemory(allocator, std.testing.io, "/tmp/missing-test-cwd");
    defer manager.deinit();

    const issue = getMissingSessionCwdIssue(std.testing.io, &manager, "/tmp");
    try std.testing.expect(issue == null);
}

test "getMissingSessionCwdIssue ignores existing stored cwd" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const project_dir = try makeMissingCwdTestPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const session_dir = try makeMissingCwdTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var manager = try session_manager_mod.SessionManager.create(
        allocator,
        std.testing.io,
        project_dir,
        session_dir,
    );
    defer manager.deinit();

    const issue = getMissingSessionCwdIssue(std.testing.io, &manager, "/tmp");
    try std.testing.expect(issue == null);
}

test "getMissingSessionCwdIssue reports missing stored cwd with session file context" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const project_dir = try makeMissingCwdTestPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const session_dir = try makeMissingCwdTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var manager = try session_manager_mod.SessionManager.create(
        allocator,
        std.testing.io,
        project_dir,
        session_dir,
    );
    defer manager.deinit();
    const session_file_path = try allocator.dupe(u8, manager.getSessionFile().?);
    defer allocator.free(session_file_path);

    // Delete the project directory so the stored cwd no longer exists.
    try tmp.dir.deleteTree(std.testing.io, "project");

    const issue = getMissingSessionCwdIssue(std.testing.io, &manager, "/private/tmp") orelse {
        return error.TestUnexpectedNullIssue;
    };
    try std.testing.expectEqualStrings(project_dir, issue.session_cwd);
    try std.testing.expectEqualStrings("/private/tmp", issue.fallback_cwd);
    try std.testing.expect(issue.session_file != null);
    try std.testing.expectEqualStrings(session_file_path, issue.session_file.?);
}

test "formatMissingSessionCwdError includes session file when present" {
    const allocator = std.testing.allocator;
    const issue = MissingSessionCwdIssue{
        .session_file = "/tmp/sessions/abc.jsonl",
        .session_cwd = "/tmp/missing",
        .fallback_cwd = "/tmp/current",
    };
    const message = try formatMissingSessionCwdError(allocator, issue);
    defer allocator.free(message);
    try std.testing.expectEqualStrings(
        "Stored session working directory does not exist: /tmp/missing\nSession file: /tmp/sessions/abc.jsonl\nCurrent working directory: /tmp/current",
        message,
    );
}

test "formatMissingSessionCwdError omits session file when absent" {
    const allocator = std.testing.allocator;
    const issue = MissingSessionCwdIssue{
        .session_file = null,
        .session_cwd = "/tmp/missing",
        .fallback_cwd = "/tmp/current",
    };
    const message = try formatMissingSessionCwdError(allocator, issue);
    defer allocator.free(message);
    try std.testing.expectEqualStrings(
        "Stored session working directory does not exist: /tmp/missing\nCurrent working directory: /tmp/current",
        message,
    );
}

test "preflightMissingSessionCwd returns owned issue when stored cwd is missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const stored = try makeMissingCwdTestPath(allocator, tmp, "stored");
    defer allocator.free(stored);
    const sessions = try makeMissingCwdTestPath(allocator, tmp, "sessions");
    defer allocator.free(sessions);

    var manager = try session_manager_mod.SessionManager.create(allocator, std.testing.io, stored, sessions);
    const session_file = try allocator.dupe(u8, manager.getSessionFile().?);
    defer allocator.free(session_file);
    manager.deinit();

    try tmp.dir.deleteTree(std.testing.io, "stored");

    var captured = try preflightMissingSessionCwd(allocator, std.testing.io, session_file, "/private/tmp");
    defer if (captured) |*value| value.deinit(allocator);
    const issue = captured orelse return error.TestUnexpectedNullIssue;
    try std.testing.expectEqualStrings(stored, issue.session_cwd);
    try std.testing.expectEqualStrings("/private/tmp", issue.fallback_cwd);
    try std.testing.expectEqualStrings(session_file, issue.session_file.?);
}

test "preflightMissingSessionCwd returns null when stored cwd still exists" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const stored = try makeMissingCwdTestPath(allocator, tmp, "stored");
    defer allocator.free(stored);
    const sessions = try makeMissingCwdTestPath(allocator, tmp, "sessions");
    defer allocator.free(sessions);

    var manager = try session_manager_mod.SessionManager.create(allocator, std.testing.io, stored, sessions);
    const session_file = try allocator.dupe(u8, manager.getSessionFile().?);
    defer allocator.free(session_file);
    manager.deinit();

    const captured = try preflightMissingSessionCwd(allocator, std.testing.io, session_file, "/private/tmp");
    try std.testing.expect(captured == null);
}

test "preflightMissingSessionCwd returns null when session file does not exist" {
    const allocator = std.testing.allocator;
    const captured = try preflightMissingSessionCwd(allocator, std.testing.io, "/tmp/missing-session-file.jsonl", "/private/tmp");
    try std.testing.expect(captured == null);
}

test "formatMissingSessionCwdPrompt mirrors the TypeScript continue/cancel prompt body" {
    const allocator = std.testing.allocator;
    const issue = MissingSessionCwdIssue{
        .session_file = "/tmp/sessions/abc.jsonl",
        .session_cwd = "/tmp/missing",
        .fallback_cwd = "/tmp/current",
    };
    const prompt = try formatMissingSessionCwdPrompt(allocator, issue);
    defer allocator.free(prompt);
    try std.testing.expectEqualStrings(
        "cwd from session file does not exist\n/tmp/missing\n\ncontinue in current cwd\n/tmp/current",
        prompt,
    );
}

fn makeMissingCwdTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}
