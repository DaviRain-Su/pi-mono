const std = @import("std");
const ts_rpc_wire = @import("ts_rpc_wire.zig");
const truncate = @import("../tools/truncate.zig");

const writeJsonString = ts_rpc_wire.writeJsonString;

const DIRECT_BASH_MAX_BUFFER_BYTES = truncate.DEFAULT_MAX_BYTES * 2;

pub const CompletionCallbacks = struct {
    context: *anyopaque,
    writeCommandError: *const fn (context: *anyopaque, id: ?[]const u8, err: anyerror) void,
    enqueueBashResult: *const fn (context: *anyopaque, id: ?[]const u8, data_json: []const u8, response_sequence: usize) void,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tasks: std.ArrayList(*BashTask) = .empty,
    task_mutex: std.Io.Mutex = .init,
    next_response_sequence: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.tasks.deinit(self.allocator);
        self.tasks = .empty;
    }

    pub fn start(
        self: *Manager,
        callbacks: CompletionCallbacks,
        cwd: []const u8,
        id: ?[]const u8,
        command: []const u8,
    ) !void {
        const response_sequence = self.next_response_sequence;
        self.next_response_sequence += 1;

        const task = try BashTask.create(self.allocator, self.io, callbacks, cwd, id, command, response_sequence);
        errdefer task.joinAndDestroy();

        self.task_mutex.lockUncancelable(self.io);
        self.tasks.append(self.allocator, task) catch |err| {
            self.task_mutex.unlock(self.io);
            return err;
        };
        self.task_mutex.unlock(self.io);

        task.spawn() catch |err| {
            self.task_mutex.lockUncancelable(self.io);
            for (self.tasks.items, 0..) |candidate, index| {
                if (candidate == task) {
                    _ = self.tasks.orderedRemove(index);
                    break;
                }
            }
            self.task_mutex.unlock(self.io);
            return err;
        };
    }

    pub fn takeCompleted(self: *Manager) ?*BashTask {
        self.task_mutex.lockUncancelable(self.io);
        defer self.task_mutex.unlock(self.io);
        for (self.tasks.items, 0..) |task, index| {
            if (task.isDone()) return self.tasks.orderedRemove(index);
        }
        return null;
    }

    pub fn reapCompleted(self: *Manager) void {
        while (self.takeCompleted()) |task| {
            task.joinAndDestroy();
        }
    }

    pub fn hasActiveTask(self: *Manager) bool {
        self.reapCompleted();
        self.task_mutex.lockUncancelable(self.io);
        defer self.task_mutex.unlock(self.io);
        return self.tasks.items.len != 0;
    }

    pub fn activeTaskStarted(self: *Manager) bool {
        self.task_mutex.lockUncancelable(self.io);
        defer self.task_mutex.unlock(self.io);
        for (self.tasks.items) |task| {
            if (task.isStarted()) return true;
        }
        return false;
    }

    pub fn hasUnfinishedTask(self: *Manager) bool {
        self.task_mutex.lockUncancelable(self.io);
        defer self.task_mutex.unlock(self.io);
        for (self.tasks.items) |task| {
            if (!task.isDone()) return true;
        }
        return false;
    }

    pub fn abortActiveTask(self: *Manager) void {
        self.reapCompleted();
        self.task_mutex.lockUncancelable(self.io);
        defer self.task_mutex.unlock(self.io);
        var index = self.tasks.items.len;
        while (index > 0) {
            index -= 1;
            const task = self.tasks.items[index];
            if (!task.isDone()) {
                task.abort();
                return;
            }
        }
    }

    pub fn cancelAndJoinAll(self: *Manager) void {
        self.task_mutex.lockUncancelable(self.io);
        var tasks = self.tasks;
        self.tasks = .empty;
        for (tasks.items) |task| {
            task.abort();
        }
        self.task_mutex.unlock(self.io);
        defer tasks.deinit(self.allocator);

        for (tasks.items) |task| {
            task.joinAndDestroy();
        }
    }

    pub fn joinAll(self: *Manager) void {
        self.task_mutex.lockUncancelable(self.io);
        var tasks = self.tasks;
        self.tasks = .empty;
        self.task_mutex.unlock(self.io);
        defer tasks.deinit(self.allocator);

        for (tasks.items) |task| {
            task.joinAndDestroy();
        }
    }

    pub fn firstTaskForTest(self: *Manager) ?*BashTask {
        self.task_mutex.lockUncancelable(self.io);
        defer self.task_mutex.unlock(self.io);
        if (self.tasks.items.len == 0) return null;
        return self.tasks.items[0];
    }
};

pub const BashTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    callbacks: CompletionCallbacks,
    cwd: []u8,
    id: ?[]u8,
    command: []u8,
    response_sequence: usize,
    abort_signal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        callbacks: CompletionCallbacks,
        cwd: []const u8,
        id: ?[]const u8,
        command: []const u8,
        response_sequence: usize,
    ) !*BashTask {
        const task = try allocator.create(BashTask);
        errdefer allocator.destroy(task);
        const cwd_copy = try allocator.dupe(u8, cwd);
        errdefer allocator.free(cwd_copy);
        const id_copy = if (id) |id_string| try allocator.dupe(u8, id_string) else null;
        errdefer if (id_copy) |id_string| allocator.free(id_string);
        const command_copy = try allocator.dupe(u8, command);
        errdefer allocator.free(command_copy);
        task.* = .{
            .allocator = allocator,
            .io = io,
            .callbacks = callbacks,
            .cwd = cwd_copy,
            .id = id_copy,
            .command = command_copy,
            .response_sequence = response_sequence,
        };
        return task;
    }

    fn spawn(self: *BashTask) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *BashTask) void {
        defer self.done.store(true, .seq_cst);
        var result = runDirectBash(
            self.allocator,
            self.io,
            self.cwd,
            self.command,
            &self.abort_signal,
            &self.started,
        ) catch |err| {
            self.callbacks.writeCommandError(self.callbacks.context, self.id, err);
            return;
        };
        defer result.deinit(self.allocator);

        const data = buildBashResultJson(self.allocator, result) catch |err| {
            self.callbacks.writeCommandError(self.callbacks.context, self.id, err);
            return;
        };
        defer self.allocator.free(data);
        self.callbacks.enqueueBashResult(self.callbacks.context, self.id, data, self.response_sequence);
    }

    fn isDone(self: *const BashTask) bool {
        return self.done.load(.seq_cst);
    }

    fn isStarted(self: *const BashTask) bool {
        return self.started.load(.seq_cst);
    }

    fn abort(self: *BashTask) void {
        self.abort_signal.store(true, .seq_cst);
    }

    pub fn isAbortRequestedForTest(self: *const BashTask) bool {
        return self.abort_signal.load(.seq_cst);
    }

    fn joinAndDestroy(self: *BashTask) void {
        if (self.thread) |thread| {
            thread.join();
        }
        self.allocator.free(self.cwd);
        if (self.id) |id_string| self.allocator.free(id_string);
        self.allocator.free(self.command);
        self.allocator.destroy(self);
    }
};

pub const BashRunResult = struct {
    output: []u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool = false,
    full_output_path: ?[]u8 = null,

    fn deinit(self: *BashRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

fn exitCodeFromTerm(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

const BashWaitState = struct {
    child: *std.process.Child,
    io: std.Io,
    term: ?std.process.Child.Term = null,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const BashOutputReaderState = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    sanitizer: DirectBashUtf8Sanitizer = .{},
    chunks: std.ArrayList([]u8) = .empty,
    output_bytes: usize = 0,
    total_raw_bytes: usize = 0,
    temp_file: ?DirectBashTempFile = null,
    err: ?anyerror = null,

    fn deinit(self: *BashOutputReaderState) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        if (self.temp_file) |*temp_file| temp_file.deinit(self.allocator, self.io);
        self.file.close(self.io);
    }

    fn appendRaw(self: *BashOutputReaderState, bytes: []const u8) !void {
        self.total_raw_bytes += bytes.len;
        const sanitized = try self.sanitizer.sanitizeChunk(self.allocator, bytes);
        try self.appendSanitized(sanitized);
    }

    fn appendSanitized(self: *BashOutputReaderState, sanitized: []u8) !void {
        errdefer self.allocator.free(sanitized);

        if (self.total_raw_bytes > truncate.DEFAULT_MAX_BYTES and self.temp_file == null) {
            try self.ensureTempFile();
        }
        if (self.temp_file) |*temp_file| {
            try temp_file.file.?.writeStreamingAll(self.io, sanitized);
        }

        if (sanitized.len == 0) {
            self.allocator.free(sanitized);
            return;
        }
        try self.chunks.append(self.allocator, sanitized);
        self.output_bytes += sanitized.len;

        while (self.output_bytes > DIRECT_BASH_MAX_BUFFER_BYTES and self.chunks.items.len > 1) {
            const removed = self.chunks.orderedRemove(0);
            self.output_bytes -= removed.len;
            self.allocator.free(removed);
        }
    }

    fn ensureTempFile(self: *BashOutputReaderState) !void {
        var temp_file = try DirectBashTempFile.create(self.allocator, self.io);
        errdefer temp_file.deinit(self.allocator, self.io);
        for (self.chunks.items) |chunk| {
            try temp_file.file.?.writeStreamingAll(self.io, chunk);
        }
        self.temp_file = temp_file;
    }

    fn finish(self: *BashOutputReaderState, result_allocator: std.mem.Allocator) !DirectBashBufferedOutput {
        const flushed = try self.sanitizer.flush(self.allocator);
        try self.appendSanitized(flushed);

        const rolling_output = try std.mem.join(result_allocator, "", self.chunks.items);
        errdefer result_allocator.free(rolling_output);
        if (self.temp_file) |*temp_file| {
            temp_file.file.?.close(self.io);
            temp_file.file = null;
            return .{
                .output = rolling_output,
                .full_output_path = temp_file.releasePath(),
            };
        }
        return .{
            .output = rolling_output,
            .full_output_path = null,
        };
    }
};

const DirectBashBufferedOutput = struct {
    output: []u8,
    full_output_path: ?[]u8 = null,

    fn deinit(self: *DirectBashBufferedOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const DirectBashTempFile = struct {
    file: ?std.Io.File,
    path: ?[]u8,

    fn create(allocator: std.mem.Allocator, io: std.Io) !DirectBashTempFile {
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            var random_bytes: [16]u8 = undefined;
            io.random(&random_bytes);
            const encoded = std.fmt.bytesToHex(random_bytes, .lower);
            const path = try std.fmt.allocPrint(allocator, "/tmp/pi-bash-{s}.log", .{encoded[0..]});
            errdefer allocator.free(path);

            var file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => return err,
            };
            errdefer file.close(io);

            return .{
                .file = file,
                .path = path,
            };
        }

        return error.TemporaryFilePathCollision;
    }

    fn releasePath(self: *DirectBashTempFile) []u8 {
        const path = self.path.?;
        self.path = null;
        return path;
    }

    fn deinit(self: *DirectBashTempFile, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.file) |file| file.close(io);
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const DirectBashUtf8Sanitizer = struct {
    pending_utf8: [4]u8 = undefined,
    pending_utf8_len: u8 = 0,

    fn sanitizeChunk(self: *DirectBashUtf8Sanitizer, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var index: usize = 0;
        try self.drainPending(allocator, &out, bytes, &index);

        while (index < bytes.len) {
            if (bytes[index] == 0x1b) {
                index = skipAnsiEscape(bytes, index);
                continue;
            }

            const start = index;
            const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[start]) catch {
                try appendUtf8Codepoint(allocator, &out, 0xfffd);
                index += 1;
                continue;
            };
            if (start + sequence_len > bytes.len) {
                var continuation_index = start + 1;
                while (continuation_index < bytes.len) : (continuation_index += 1) {
                    if (!isUtf8Continuation(bytes[continuation_index])) {
                        try appendUtf8Codepoint(allocator, &out, 0xfffd);
                        index += 1;
                        break;
                    }
                } else {
                    const remaining = bytes[start..];
                    @memcpy(self.pending_utf8[0..remaining.len], remaining);
                    self.pending_utf8_len = @intCast(remaining.len);
                    index = bytes.len;
                }
                continue;
            }

            const slice = bytes[start .. start + sequence_len];
            const codepoint = std.unicode.utf8Decode(slice) catch {
                try appendUtf8Codepoint(allocator, &out, 0xfffd);
                index += 1;
                continue;
            };
            index += sequence_len;

            try appendSanitizedCodepoint(allocator, &out, slice, codepoint);
        }

        return try out.toOwnedSlice(allocator);
    }

    fn drainPending(
        self: *DirectBashUtf8Sanitizer,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        bytes: []const u8,
        index: *usize,
    ) !void {
        if (self.pending_utf8_len == 0) return;

        const sequence_len = std.unicode.utf8ByteSequenceLength(self.pending_utf8[0]) catch {
            try appendUtf8Codepoint(allocator, out, 0xfffd);
            self.pending_utf8_len = 0;
            return;
        };

        while (self.pending_utf8_len < sequence_len) {
            if (index.* >= bytes.len) return;
            const byte = bytes[index.*];
            if (!isUtf8Continuation(byte)) {
                try appendUtf8Codepoint(allocator, out, 0xfffd);
                self.pending_utf8_len = 0;
                return;
            }
            self.pending_utf8[self.pending_utf8_len] = byte;
            self.pending_utf8_len += 1;
            index.* += 1;
        }

        const slice = self.pending_utf8[0..sequence_len];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            try appendUtf8Codepoint(allocator, out, 0xfffd);
            self.pending_utf8_len = 0;
            return;
        };
        try appendSanitizedCodepoint(allocator, out, slice, codepoint);
        self.pending_utf8_len = 0;
    }

    fn flush(self: *DirectBashUtf8Sanitizer, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (self.pending_utf8_len != 0) {
            try appendUtf8Codepoint(allocator, &out, 0xfffd);
            self.pending_utf8_len = 0;
        }
        return try out.toOwnedSlice(allocator);
    }
};

pub fn sanitizeDirectBashOutput(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var sanitizer: DirectBashUtf8Sanitizer = .{};
    const chunk = try sanitizer.sanitizeChunk(allocator, bytes);
    defer allocator.free(chunk);
    const flushed = try sanitizer.flush(allocator);
    defer allocator.free(flushed);
    return try std.mem.concat(allocator, u8, &.{ chunk, flushed });
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn appendSanitizedCodepoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    slice: []const u8,
    codepoint: u21,
) !void {
    if (codepoint == '\t' or codepoint == '\n') {
        try out.appendSlice(allocator, slice);
    } else if (codepoint == '\r') {
        return;
    } else if (codepoint <= 0x1f) {
        return;
    } else if (codepoint >= 0xfff9 and codepoint <= 0xfffb) {
        return;
    } else {
        try out.appendSlice(allocator, slice);
    }
}

fn skipAnsiEscape(bytes: []const u8, start: usize) usize {
    if (start + 1 >= bytes.len) return start + 1;

    const introducer = bytes[start + 1];
    if (introducer == '[') {
        var index = start + 2;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] >= 0x40 and bytes[index] <= 0x7e) return index + 1;
        }
        return bytes.len;
    }

    if (introducer == ']') {
        var index = start + 2;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] == 0x07) return index + 1;
            if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '\\') return index + 2;
        }
        return bytes.len;
    }

    return start + 2;
}

fn appendUtf8Codepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(codepoint, &buffer);
    try out.appendSlice(allocator, buffer[0..len]);
}

fn waitDirectBashChild(state: *BashWaitState) void {
    state.term = state.child.wait(state.io) catch |err| {
        state.err = err;
        state.done.store(true, .seq_cst);
        return;
    };
    state.done.store(true, .seq_cst);
}

fn readDirectBashOutput(state: *BashOutputReaderState) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = state.file.readStreaming(state.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                state.err = err;
                return;
            },
        };
        if (bytes_read == 0) return;
        state.appendRaw(buffer[0..bytes_read]) catch |err| {
            state.err = err;
            return;
        };
    }
}

fn killDirectBashProcessGroup(pid: std.process.Child.Id) void {
    if (@import("builtin").os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(pid, @enumFromInt(@as(u32, 1)));
    } else {
        std.posix.kill(-pid, .TERM) catch {};
        std.posix.kill(-pid, .KILL) catch {};
    }
}

pub fn runDirectBash(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    abort_signal: *const std.atomic.Value(bool),
    started: *std.atomic.Value(bool),
) !BashRunResult {
    var cwd_dir = std.Io.Dir.openDirAbsolute(io, cwd, .{}) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Working directory does not exist: {s} ({s})", .{ cwd, @errorName(err) });
        defer allocator.free(message);
        return .{
            .output = try allocator.dupe(u8, message),
            .exit_code = null,
            .cancelled = abort_signal.load(.seq_cst),
        };
    };
    defer cwd_dir.close(io);

    const builtin = @import("builtin");
    var argv_buf: [3][]const u8 = undefined;
    var argv_len: usize = 0;
    if (builtin.os.tag == .windows) {
        argv_buf[0] = "bash";
        argv_buf[1] = "-c";
        argv_buf[2] = try std.fmt.allocPrint(allocator, "exec 2>&1\n{s}", .{command});
        argv_len = 3;
    } else {
        argv_buf[0] = "/bin/sh";
        argv_buf[1] = "-c";
        argv_buf[2] = try std.fmt.allocPrint(allocator, "exec 2>&1\n{s}", .{command});
        argv_len = 3;
    }
    const argv = argv_buf[0..argv_len];
    defer allocator.free(argv[2]);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    defer {
        if (child.id != null) child.kill(io);
    }
    const pid = child.id.?;
    started.store(true, .seq_cst);

    const stdout_file = child.stdout.?;
    child.stdout = null;

    var wait_state = BashWaitState{
        .child = &child,
        .io = io,
    };
    const wait_thread = try std.Thread.spawn(.{}, waitDirectBashChild, .{&wait_state});

    var reader_state = BashOutputReaderState{
        .allocator = allocator,
        .file = stdout_file,
        .io = io,
    };
    const reader_thread = std.Thread.spawn(.{}, readDirectBashOutput, .{&reader_state}) catch |err| {
        killDirectBashProcessGroup(pid);
        wait_thread.join();
        reader_state.deinit();
        return err;
    };

    var threads_joined = false;
    defer {
        if (!threads_joined) {
            wait_thread.join();
            reader_thread.join();
        }
        reader_state.deinit();
    }

    var cancelled = false;
    while (!wait_state.done.load(.seq_cst)) {
        if (abort_signal.load(.seq_cst)) {
            cancelled = true;
            killDirectBashProcessGroup(pid);
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }

    wait_thread.join();
    reader_thread.join();
    threads_joined = true;

    if (reader_state.err) |err| return err;
    if (wait_state.err) |err| return err;

    var buffered_output = try reader_state.finish(allocator);
    defer buffered_output.deinit(allocator);
    var truncation_result = try truncate.truncateTail(allocator, buffered_output.output, .{});
    defer truncation_result.deinit(allocator);

    var full_output_path = buffered_output.full_output_path;
    buffered_output.full_output_path = null;
    errdefer if (full_output_path) |path| allocator.free(path);

    if (truncation_result.truncated and full_output_path == null) {
        full_output_path = try captureDirectBashOutputInTempFile(allocator, io, buffered_output.output);
    }

    return .{
        .output = if (truncation_result.truncated)
            try allocator.dupe(u8, truncation_result.content)
        else
            try allocator.dupe(u8, buffered_output.output),
        .exit_code = if (cancelled) null else exitCodeFromTerm(wait_state.term.?),
        .cancelled = cancelled,
        .truncated = truncation_result.truncated,
        .full_output_path = full_output_path,
    };
}

fn captureDirectBashOutputInTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
) ![]u8 {
    var temp_file = try DirectBashTempFile.create(allocator, io);
    errdefer temp_file.deinit(allocator, io);
    try temp_file.file.?.writeStreamingAll(io, output);
    temp_file.file.?.close(io);
    temp_file.file = null;
    return temp_file.releasePath();
}

pub fn buildBashResultJson(allocator: std.mem.Allocator, result: BashRunResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"output\":");
    try writeJsonString(allocator, &out.writer, result.output);
    if (result.exit_code) |code| {
        try out.writer.print(",\"exitCode\":{d}", .{code});
    }
    try out.writer.writeAll(",\"cancelled\":");
    try out.writer.writeAll(if (result.cancelled) "true" else "false");
    try out.writer.writeAll(",\"truncated\":");
    try out.writer.writeAll(if (result.truncated) "true" else "false");
    if (result.full_output_path) |path| {
        try out.writer.writeAll(",\"fullOutputPath\":");
        try writeJsonString(allocator, &out.writer, path);
    }
    try out.writer.writeAll("}");
    return try allocator.dupe(u8, out.written());
}
