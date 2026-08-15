const std = @import("std");
const builtin = @import("builtin");
const abort_helper = @import("shared/abort_signal.zig");
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
};

pub const HttpError = error{
    ConnectionRefused,
    ConnectionReset,
    Timeout,
    RequestAborted,
    InvalidUrl,
    UnknownHost,
    TlsFailure,
    TooManyRedirects,
    NetworkUnreachable,
    ServerError,
    ClientError,
    UnexpectedRedirect,
    StreamLineTooLong,
    ResponseBodyTooLarge,
};

/// Maximum bytes retained for a single streaming/SSE line before a newline.
/// Provider SSE events are normally small; keep this generous but finite so an
/// unterminated line cannot drive unbounded allocation.
pub const max_stream_line_bytes: usize = 4 * 1024 * 1024;

/// Live HTTP transfer buffering for streaming readers. Keep this intentionally
/// independent from max_stream_line_bytes so throughput tuning cannot lower the
/// security cap for long SSE lines.
const live_stream_transfer_buffer_bytes: usize = 16 * 1024;

/// Maximum decompressed bytes retained by one-shot/non-streaming HTTP requests.
/// Model discovery and OAuth/token endpoints are expected to be far smaller;
/// 32 MiB keeps legitimate JSON payloads working while preventing unbounded
/// allocation through std.http's response writer.
pub const max_response_body_bytes: usize = 32 * 1024 * 1024;

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const HttpResponse) void {
        self.allocator.free(self.body);
    }
};

const DeadlineTerminationReason = enum(u8) {
    none,
    aborted,
    timeout,
};

/// Shared watchdog for request setup and live streaming deadlines.
/// The guard only signals deadlines by invoking the configured shutdown stream;
/// callers continue to own and deinit requests, connections, and response state.
const HttpDeadlineGuard = struct {
    io: ?std.Io = null,
    shutdown_stream: ?std.Io.net.Stream = null,
    request: ?*std.http.Client.Request = null,
    aborted: ?*const std.atomic.Value(bool) = null,
    timeout_ms: u32 = 0,
    created_at_ns: i128 = 0,
    thread: ?std.Thread = null,
    started: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    termination_reason: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(DeadlineTerminationReason.none)),

    fn init(
        io: std.Io,
        shutdown_stream: ?std.Io.net.Stream,
        request: ?*std.http.Client.Request,
        aborted: ?*const std.atomic.Value(bool),
        timeout_ms: u32,
        created_at_ns: i128,
    ) HttpDeadlineGuard {
        return .{
            .io = io,
            .shutdown_stream = shutdown_stream,
            .request = request,
            .aborted = aborted,
            .timeout_ms = timeout_ms,
            .created_at_ns = created_at_ns,
        };
    }

    fn start(self: *HttpDeadlineGuard) !void {
        if (self.started) return;
        if (self.io == null) return;
        if (self.aborted == null and self.timeout_ms == 0) return;

        self.started = true;
        self.thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
    }

    fn deinit(self: *HttpDeadlineGuard) void {
        self.done.store(true, .release);
        if (self.thread) |thread| thread.join();
    }

    fn watchdogMain(self: *HttpDeadlineGuard) void {
        const io = self.io orelse return;

        while (!self.done.load(.acquire)) {
            if (abort_helper.isRequested(self.aborted)) {
                self.triggerTermination(.aborted);
                return;
            }

            if (self.timeout_ms > 0) {
                const now_ns = std.Io.Clock.now(.awake, io).nanoseconds;
                const timeout_ns: i128 = @as(i128, self.timeout_ms) * std.time.ns_per_ms;
                if (now_ns - self.created_at_ns >= timeout_ns) {
                    self.triggerTermination(.timeout);
                    return;
                }
            }

            const sleep_ms: i64 = if (self.timeout_ms == 0) 10 else 1;
            std.Io.sleep(io, .fromMilliseconds(sleep_ms), .awake) catch return;
        }
    }

    fn triggerTermination(self: *HttpDeadlineGuard, reason: DeadlineTerminationReason) void {
        self.termination_reason.store(@intFromEnum(reason), .release);

        if (self.request) |request| {
            if (request.connection) |connection| connection.closing = true;
        }

        if (self.shutdown_stream) |stream| {
            const io = self.io orelse return;
            stream.shutdown(io, .both) catch {};
        }
    }

    fn currentTerminationReason(self: *const HttpDeadlineGuard) ?DeadlineTerminationReason {
        return switch (@as(DeadlineTerminationReason, @enumFromInt(self.termination_reason.load(.acquire)))) {
            .none => null,
            .aborted => .aborted,
            .timeout => .timeout,
        };
    }

    fn check(self: *const HttpDeadlineGuard) !void {
        if (self.currentTerminationReason()) |reason| return terminationError(reason);
    }
};

fn terminationError(reason: DeadlineTerminationReason) HttpError {
    return switch (reason) {
        .none => unreachable,
        .aborted => HttpError.RequestAborted,
        .timeout => HttpError.Timeout,
    };
}

/// A streaming response that yields lines from a buffered body.
/// Owns the response body and provides line-by-line iteration.
pub const StreamingResponse = struct {
    status: u16,
    body: []const u8,
    pos: usize = 0,
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    response_headers: ?std.StringHashMap([]const u8) = null,
    done: bool = false,
    owns_body: bool = true,
    request: ?*std.http.Client.Request = null,
    reader: ?*std.Io.Reader = null,
    transfer_buffer: []u8 = &.{},
    decompress: std.http.Decompress = undefined,
    decompress_buffer: []u8 = &.{},
    redirect_buffer: []u8 = &.{},
    extra_headers: []std.http.Header = &.{},
    deadline_guard: HttpDeadlineGuard = .{},

    pub fn deinit(self: *StreamingResponse) void {
        self.deadline_guard.deinit();

        if (self.request) |request| {
            request.deinit();
            self.allocator.destroy(request);
        }
        if (self.owns_body) self.allocator.free(self.body);
        if (self.response_headers) |*headers| deinitOwnedHeaders(self.allocator, headers);
        if (self.transfer_buffer.len > 0) self.allocator.free(self.transfer_buffer);
        if (self.decompress_buffer.len > 0) self.allocator.free(self.decompress_buffer);
        if (self.redirect_buffer.len > 0) self.allocator.free(self.redirect_buffer);
        if (self.extra_headers.len > 0) self.allocator.free(self.extra_headers);
        self.buffer.deinit(self.allocator);
    }

    /// Read the next line from the buffered body. Returns a slice into an
    /// internal buffer that is valid until the next call to readLine.
    pub fn readLine(self: *StreamingResponse) !?[]const u8 {
        if (self.done) return null;
        if (self.reader != null) return self.readLiveLine();
        return self.readBufferedLine();
    }

    /// Consume the rest of the stream into a single buffer.
    pub fn readAll(self: *StreamingResponse, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        while (try self.readLine()) |line| {
            try result.appendSlice(allocator, line);
            try result.append(allocator, '\n');
        }

        return result.toOwnedSlice(allocator);
    }

    /// Consume up to max_bytes from the rest of the stream into a single buffer.
    /// This is intended for provider error bodies where callers only need enough
    /// bytes for bounded diagnostics and should not read an unbounded response.
    pub fn readAllBounded(self: *StreamingResponse, allocator: std.mem.Allocator, max_bytes: usize) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        if (max_bytes == 0) {
            self.done = true;
            return result.toOwnedSlice(allocator);
        }

        if (self.reader == null) {
            if (self.pos >= self.body.len) {
                self.done = true;
                return result.toOwnedSlice(allocator);
            }
            const remaining = self.body[self.pos..];
            const copy_len = @min(remaining.len, max_bytes);
            try result.appendSlice(allocator, remaining[0..copy_len]);
            self.pos += copy_len;
            if (self.pos >= self.body.len or result.items.len >= max_bytes) self.done = true;
            return result.toOwnedSlice(allocator);
        }

        try self.ensureWatchdogStarted();
        const reader = self.reader.?;
        while (result.items.len < max_bytes) {
            if (self.currentTerminationReason()) |reason| {
                self.done = true;
                return terminationError(reason);
            }

            const byte = reader.takeByte() catch |err| {
                if (self.currentTerminationReason()) |reason| {
                    self.done = true;
                    return terminationError(reason);
                }
                if (err == error.EndOfStream) {
                    self.done = true;
                    break;
                }
                return err;
            };
            try result.append(allocator, byte);
        }

        if (result.items.len >= max_bytes) self.done = true;
        return result.toOwnedSlice(allocator);
    }

    fn readBufferedLine(self: *StreamingResponse) !?[]const u8 {
        if (self.pos >= self.body.len) {
            self.done = true;
            return null;
        }

        self.buffer.clearRetainingCapacity();
        const remaining = self.body[self.pos..];

        if (std.mem.indexOfScalar(u8, remaining, '\n')) |newline_index| {
            const line = remaining[0..newline_index];
            if (line.len > max_stream_line_bytes) {
                try self.failBufferedLineTooLong(remaining);
            }

            try self.appendLineSlice(line);
            self.pos += newline_index + 1;
            trimTrailingCarriageReturn(&self.buffer);
            return self.buffer.items;
        }

        if (remaining.len > max_stream_line_bytes) {
            try self.failBufferedLineTooLong(remaining);
        }

        try self.appendLineSlice(remaining);
        self.pos = self.body.len;
        self.done = true;
        return self.buffer.items;
    }

    fn readLiveLine(self: *StreamingResponse) !?[]const u8 {
        try self.ensureWatchdogStarted();
        if (self.currentTerminationReason()) |reason| {
            self.done = true;
            return terminationError(reason);
        }

        self.buffer.clearRetainingCapacity();
        const reader = self.reader.?;

        var line_writer = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.buffer);
        var restored_buffer = false;
        defer {
            if (!restored_buffer) self.buffer = line_writer.toArrayList();
        }

        const hit_limit = blk: {
            _ = reader.streamDelimiterLimit(
                &line_writer.writer,
                '\n',
                .limited(max_stream_line_bytes),
            ) catch |err| switch (err) {
                error.StreamTooLong => break :blk true,
                error.ReadFailed => {
                    if (self.currentTerminationReason()) |reason| {
                        self.done = true;
                        return terminationError(reason);
                    }
                    return err;
                },
                error.WriteFailed => return error.OutOfMemory,
            };
            break :blk false;
        };

        self.buffer = line_writer.toArrayList();
        restored_buffer = true;

        if (hit_limit) return self.finishMaxSizedLiveLine(reader);
        return self.consumeLiveLineDelimiter(reader);
    }

    fn appendLineSlice(self: *StreamingResponse, bytes: []const u8) !void {
        if (bytes.len > max_stream_line_bytes - self.buffer.items.len) {
            self.done = true;
            return HttpError.StreamLineTooLong;
        }
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    fn failBufferedLineTooLong(self: *StreamingResponse, remaining: []const u8) !noreturn {
        const consume_len = @min(remaining.len, max_stream_line_bytes + 1);
        const retain_len = @min(max_stream_line_bytes, consume_len);
        if (retain_len > 0) try self.buffer.appendSlice(self.allocator, remaining[0..retain_len]);
        self.pos += consume_len;
        self.done = true;
        return HttpError.StreamLineTooLong;
    }

    fn consumeLiveLineDelimiter(self: *StreamingResponse, reader: *std.Io.Reader) !?[]const u8 {
        // streamDelimiterLimit stops at the '\n' but does not consume it, so we
        // discard exactly that one delimiter byte here. Any error must be
        // interpreted relative to deadline/abort state observed by the watchdog.
        reader.discardAll(1) catch |err| {
            if (self.currentTerminationReason()) |reason| {
                self.done = true;
                return terminationError(reason);
            }

            if (err == error.EndOfStream) {
                self.done = true;
                if (self.buffer.items.len == 0) return null;
                trimTrailingCarriageReturn(&self.buffer);
                return self.buffer.items;
            }

            return err;
        };

        trimTrailingCarriageReturn(&self.buffer);
        return self.buffer.items;
    }

    fn finishMaxSizedLiveLine(self: *StreamingResponse, reader: *std.Io.Reader) !?[]const u8 {
        if (self.currentTerminationReason()) |reason| {
            self.done = true;
            return terminationError(reason);
        }

        const byte = reader.takeByte() catch |err| {
            if (self.currentTerminationReason()) |reason| {
                self.done = true;
                return terminationError(reason);
            }

            if (err == error.EndOfStream) {
                self.done = true;
                trimTrailingCarriageReturn(&self.buffer);
                return self.buffer.items;
            }

            return err;
        };

        if (byte == '\n') {
            trimTrailingCarriageReturn(&self.buffer);
            return self.buffer.items;
        }

        self.done = true;
        return HttpError.StreamLineTooLong;
    }

    fn ensureWatchdogStarted(self: *StreamingResponse) !void {
        try self.deadline_guard.start();
    }

    fn currentTerminationReason(self: *const StreamingResponse) ?DeadlineTerminationReason {
        return self.deadline_guard.currentTerminationReason();
    }

    fn trimTrailingCarriageReturn(buffer: *std.ArrayList(u8)) void {
        if (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '\r') {
            buffer.shrinkRetainingCapacity(buffer.items.len - 1);
        }
    }
};

pub const HttpRequest = struct {
    method: HttpMethod = .POST,
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
    /// Request timeout in milliseconds. 0 means no timeout.
    timeout_ms: u32 = 0,
    /// Optional abort signal. If true, the request should be aborted.
    aborted: ?*const std.atomic.Value(bool) = null,
    /// Maximum decompressed response body bytes for non-streaming request().
    max_response_body_bytes: usize = max_response_body_bytes,
};

fn httpMethodFor(method: HttpMethod) std.http.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        .PATCH => .PATCH,
    };
}

fn cloneRequestHeaders(
    allocator: std.mem.Allocator,
    headers: ?std.StringHashMap([]const u8),
) ![]std.http.Header {
    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers.deinit(allocator);

    if (headers) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            try extra_headers.append(allocator, .{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            });
        }
    }

    return extra_headers.toOwnedSlice(allocator);
}

fn sendRequestWithDeadline(
    request: *std.http.Client.Request,
    body: ?[]const u8,
    deadline_guard: *const HttpDeadlineGuard,
) !void {
    if (body) |bytes| {
        request.transfer_encoding = .{ .content_length = bytes.len };
        var body_writer = request.sendBodyUnflushed(&.{}) catch |err| {
            try deadline_guard.check();
            return err;
        };
        try deadline_guard.check();
        body_writer.writer.writeAll(bytes) catch |err| {
            try deadline_guard.check();
            return err;
        };
        try deadline_guard.check();
        body_writer.end() catch |err| {
            try deadline_guard.check();
            return err;
        };
        try deadline_guard.check();
        request.connection.?.flush() catch |err| {
            try deadline_guard.check();
            return err;
        };
        try deadline_guard.check();
    } else {
        request.sendBodiless() catch |err| {
            try deadline_guard.check();
            return err;
        };
        try deadline_guard.check();
    }
}

fn hasDeadlineExpired(timeout_ms: u32, started_at_ns: i128, io: std.Io) bool {
    if (timeout_ms == 0) return false;
    const now_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;
    return now_ns - started_at_ns >= timeout_ns;
}

fn remainingTimeout(timeout_ms: u32, started_at_ns: i128, io: std.Io) !std.Io.Timeout {
    if (timeout_ms == 0) return .none;
    const now_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;
    const deadline_ns = started_at_ns + timeout_ns;
    if (now_ns >= deadline_ns) return HttpError.Timeout;
    const remaining_ns = deadline_ns - now_ns;
    return .{ .duration = .{
        .raw = .fromNanoseconds(@intCast(@max(remaining_ns, std.time.ns_per_ms))),
        .clock = .awake,
    } };
}

fn isDeadlineRequested(req: HttpRequest) bool {
    return req.timeout_ms != 0 or req.aborted != null;
}

fn protocolDefaultPort(protocol: std.http.Client.Protocol) u16 {
    return switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

fn resolveTimeoutAwareAddress(host: std.Io.net.HostName, port: u16) ?std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host.bytes, port)) |address| return address else |_| {}

    if (std.ascii.eqlIgnoreCase(host.bytes, "localhost") or
        std.ascii.eqlIgnoreCase(host.bytes, "localhost."))
    {
        return .{ .ip4 = .loopback(port) };
    }

    if (std.ascii.endsWithIgnoreCase(host.bytes, ".localhost") or
        std.ascii.endsWithIgnoreCase(host.bytes, ".localhost."))
    {
        return .{ .ip4 = .loopback(port) };
    }

    return null;
}

const supports_posix_active_connect_deadline = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

const connect_poll_step_ms: i32 = 10;

fn pollConnectTimeoutMs(timeout_ms: u32, started_at_ns: i128, io: std.Io) !i32 {
    if (timeout_ms == 0) return connect_poll_step_ms;

    const now_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;
    const remaining_ns = started_at_ns + timeout_ns - now_ns;
    if (remaining_ns <= 0) return HttpError.Timeout;

    const remaining_ms = @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(remaining_ms, connect_poll_step_ms));
}

fn fcntlRaw(fd: std.posix.fd_t, command: c_int, arg: usize) !usize {
    while (true) {
        const rc = std.posix.system.fcntl(fd, command, arg);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => unreachable,
            .INVAL => unreachable,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn setCloseOnExecPosix(fd: std.posix.fd_t) !void {
    _ = try fcntlRaw(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
}

fn setSocketNonblockingPosix(fd: std.posix.fd_t, enabled: bool) !void {
    const flags_value = try fcntlRaw(fd, std.posix.F.GETFL, 0);
    var flags: std.posix.O = @bitCast(@as(u32, @intCast(flags_value)));
    flags.NONBLOCK = enabled;
    _ = try fcntlRaw(fd, std.posix.F.SETFL, @as(u32, @bitCast(flags)));
}

fn socketIsNonblockingPosix(fd: std.posix.fd_t) !bool {
    const flags_value = try fcntlRaw(fd, std.posix.F.GETFL, 0);
    const flags: std.posix.O = @bitCast(@as(u32, @intCast(flags_value)));
    return flags.NONBLOCK;
}

fn openTcpSocketPosix(address: *const std.Io.net.IpAddress) !std.posix.fd_t {
    const family = std.Io.Threaded.posixAddressFamily(address);
    while (true) {
        const rc = std.posix.system.socket(family, std.posix.SOCK.STREAM, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const fd: std.posix.fd_t = @intCast(rc);
                errdefer std.Io.Threaded.closeFd(fd);
                try setCloseOnExecPosix(fd);
                try setSocketNonblockingPosix(fd, true);
                return fd;
            },
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn mapConnectErrno(err: std.posix.E) !void {
    return switch (err) {
        .SUCCESS => {},
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .CONNREFUSED => HttpError.ConnectionRefused,
        .CONNRESET => HttpError.ConnectionReset,
        .HOSTUNREACH, .NETUNREACH => HttpError.NetworkUnreachable,
        .TIMEDOUT => HttpError.Timeout,
        .ACCES => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        .BADF, .CONNABORTED, .FAULT, .ISCONN, .NOENT, .NOTSOCK, .PERM, .PROTOTYPE => error.Unexpected,
        else => std.posix.unexpectedErrno(err),
    };
}

fn socketConnectErrorPosix(fd: std.posix.fd_t) !void {
    var socket_error: c_int = 0;
    var socket_error_len: std.posix.socklen_t = @sizeOf(c_int);
    const rc = std.posix.system.getsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.ERROR,
        @ptrCast(&socket_error),
        &socket_error_len,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .BADF, .FAULT, .INVAL, .NOTSOCK => return error.Unexpected,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    try mapConnectErrno(@enumFromInt(socket_error));
}

fn waitForConnectPosix(
    fd: std.posix.fd_t,
    req: HttpRequest,
    started_at_ns: i128,
    io: std.Io,
) !void {
    while (true) {
        if (abort_helper.isRequested(req.aborted)) return HttpError.RequestAborted;

        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, try pollConnectTimeoutMs(req.timeout_ms, started_at_ns, io));
        if (ready == 0) continue;
        if ((poll_fds[0].revents & std.posix.POLL.NVAL) != 0) return error.Unexpected;
        try socketConnectErrorPosix(fd);
        return;
    }
}

fn connectTcpDeadlinePosix(
    address: std.Io.net.IpAddress,
    req: HttpRequest,
    started_at_ns: i128,
    io: std.Io,
) !std.Io.net.Stream {
    if (abort_helper.isRequested(req.aborted)) return HttpError.RequestAborted;
    _ = try pollConnectTimeoutMs(req.timeout_ms, started_at_ns, io);

    const fd = try openTcpSocketPosix(&address);
    errdefer std.Io.Threaded.closeFd(fd);

    var storage: std.Io.Threaded.PosixAddress = undefined;
    const address_len = std.Io.Threaded.addressToPosix(&address, &storage);
    while (true) {
        switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, address_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .AGAIN, .INPROGRESS, .ALREADY => {
                try waitForConnectPosix(fd, req, started_at_ns, io);
                break;
            },
            else => |err| try mapConnectErrno(err),
        }
    }

    if (abort_helper.isRequested(req.aborted)) return HttpError.RequestAborted;
    if (hasDeadlineExpired(req.timeout_ms, started_at_ns, io)) return HttpError.Timeout;
    try setSocketNonblockingPosix(fd, false);

    var local_storage: std.Io.Threaded.PosixAddress = undefined;
    var local_address_len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    while (true) {
        switch (std.posix.errno(std.posix.system.getsockname(fd, &local_storage.any, &local_address_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOBUFS => return error.SystemResources,
            .BADF, .FAULT, .INVAL, .NOTSOCK => return error.Unexpected,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    return .{ .socket = .{
        .handle = fd,
        .address = std.Io.Threaded.addressFromPosix(&local_storage),
    } };
}

const LocalTlsConnection = struct {
    client: std.crypto.tls.Client,
    connection: std.http.Client.Connection,
};

/// Simple HTTP client using std.http.Client.fetch
pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,
    request_setup_failure_for_test: if (builtin.is_test) ?anyerror else void = if (builtin.is_test) null else {},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !HttpClient {
        return .{
            .client = std.http.Client{ .allocator = allocator, .io = io },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub fn request(self: *HttpClient, req: HttpRequest) !HttpResponse {
        var streaming = try self.requestStreaming(req);
        defer streaming.deinit();

        if (statusCodeError(streaming.status)) |err| return err;

        const read_limit = std.math.add(usize, req.max_response_body_bytes, 1) catch req.max_response_body_bytes;
        const body_copy = try streaming.readAllBounded(self.allocator, read_limit);
        errdefer self.allocator.free(body_copy);

        if (body_copy.len > req.max_response_body_bytes) return HttpError.ResponseBodyTooLarge;

        return HttpResponse{
            .status = streaming.status,
            .body = body_copy,
            .allocator = self.allocator,
        };
    }

    fn releaseUnadoptedTimeoutAwareConnection(self: *HttpClient, connection: ?*std.http.Client.Connection) void {
        const owned_connection = connection orelse return;
        owned_connection.closing = true;
        self.client.connection_pool.release(owned_connection, self.client.io);
    }

    fn openTimeoutAwareConnection(
        self: *HttpClient,
        uri: std.Uri,
        req: HttpRequest,
        started_at_ns: i128,
    ) !?*std.http.Client.Connection {
        if (!isDeadlineRequested(req)) return null;

        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return HttpError.InvalidUrl;

        // Keep std.http behavior for proxy-mediated requests. Zig 0.16 exposes
        // no safe hook to carry a caller deadline through proxy CONNECT setup
        // without reimplementing the full proxy path.
        if ((protocol == .plain and self.client.http_proxy != null) or
            (protocol == .tls and self.client.https_proxy != null))
        {
            return null;
        }

        var host_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_name_buffer) catch return HttpError.InvalidUrl;
        const port = uri.port orelse protocolDefaultPort(protocol);
        const address = resolveTimeoutAwareAddress(host_name, port) orelse {
            // Zig 0.16's system DNS path is not safely preemptible from here.
            // For non-local names, keep std.http's resolver/connection behavior
            // and charge elapsed time once it returns rather than overclaiming
            // full getaddrinfo cancellation.
            return null;
        };

        if (abort_helper.isRequested(req.aborted)) return HttpError.RequestAborted;
        var stream = if (supports_posix_active_connect_deadline) blk: {
            // Zig 0.16's threaded Io backend currently panics when
            // IpAddress.connect receives a non-none timeout. For local/numeric
            // hosts on Darwin/Linux, use a repo-owned nonblocking connect loop
            // with poll/SO_ERROR so the active connect phase honors deadline
            // and abort before returning a blocking stream to std.Io/TLS.
            break :blk connectTcpDeadlinePosix(address, req, started_at_ns, self.client.io) catch |err| switch (err) {
                error.Timeout => return HttpError.Timeout,
                else => |e| return e,
            };
        } else blk: {
            // Non-POSIX targets keep std.http/std.Io behavior. The timeout is
            // charged before and after connect, but active connect preemption is
            // intentionally limited to the Darwin/Linux POSIX helper above.
            _ = try remainingTimeout(req.timeout_ms, started_at_ns, self.client.io);
            break :blk address.connect(self.client.io, .{
                .mode = .stream,
                .timeout = .none,
            }) catch |err| switch (err) {
                error.Timeout => return HttpError.Timeout,
                else => |e| return e,
            };
        };
        errdefer stream.close(self.client.io);
        if (abort_helper.isRequested(req.aborted)) return HttpError.RequestAborted;
        if (hasDeadlineExpired(req.timeout_ms, started_at_ns, self.client.io)) return HttpError.Timeout;

        const connection = switch (protocol) {
            .plain => try self.createPlainTimeoutAwareConnection(host_name, port, stream),
            .tls => try self.createTlsTimeoutAwareConnection(host_name, port, stream, req, started_at_ns),
        };
        errdefer {
            connection.closing = true;
            self.client.connection_pool.release(connection, self.client.io);
        }

        self.client.connection_pool.addUsed(self.client.io, connection);
        stream = undefined;
        return connection;
    }

    fn createPlainTimeoutAwareConnection(
        self: *HttpClient,
        remote_host: std.Io.net.HostName,
        port: u16,
        stream: std.Io.net.Stream,
    ) !*std.http.Client.Connection {
        const alloc_len = @sizeOf(std.http.Client.Connection) +
            remote_host.bytes.len +
            self.client.read_buffer_size +
            self.client.write_buffer_size;
        const base = try self.allocator.alignedAlloc(u8, .of(std.http.Client.Connection), alloc_len);
        errdefer self.allocator.free(base);

        const host_buffer = base[@sizeOf(std.http.Client.Connection)..][0..remote_host.bytes.len];
        const socket_read_buffer = host_buffer.ptr[host_buffer.len..][0..self.client.read_buffer_size];
        const socket_write_buffer = socket_read_buffer.ptr[socket_read_buffer.len..][0..self.client.write_buffer_size];
        @memcpy(host_buffer, remote_host.bytes);

        // std.http.Client.Connection.Plain is private in Zig 0.16 but its
        // layout is a single `connection` field at offset 0. Allocate the same
        // layout so Request.deinit can release/destroy through std.http.
        const connection: *std.http.Client.Connection = @ptrCast(base);
        connection.* = .{
            .client = &self.client,
            .stream_writer = stream.writer(self.client.io, socket_write_buffer),
            .stream_reader = stream.reader(self.client.io, socket_read_buffer),
            .pool_node = .{},
            .port = port,
            .host_len = @intCast(remote_host.bytes.len),
            .proxied = false,
            .closing = false,
            .protocol = .plain,
        };
        return connection;
    }

    fn createTlsTimeoutAwareConnection(
        self: *HttpClient,
        remote_host: std.Io.net.HostName,
        port: u16,
        stream: std.Io.net.Stream,
        req: HttpRequest,
        started_at_ns: i128,
    ) !*std.http.Client.Connection {
        if (std.http.Client.disable_tls) return HttpError.TlsFailure;
        const tls_read_buffer_len = self.client.tls_buffer_size + self.client.read_buffer_size;
        const alloc_len = @sizeOf(LocalTlsConnection) +
            remote_host.bytes.len +
            tls_read_buffer_len +
            self.client.tls_buffer_size +
            self.client.write_buffer_size +
            self.client.tls_buffer_size;
        const base = try self.allocator.alignedAlloc(u8, .of(LocalTlsConnection), alloc_len);
        errdefer self.allocator.free(base);

        const host_buffer = base[@sizeOf(LocalTlsConnection)..][0..remote_host.bytes.len];
        const tls_read_buffer = host_buffer.ptr[host_buffer.len..][0..tls_read_buffer_len];
        const tls_write_buffer = tls_read_buffer.ptr[tls_read_buffer.len..][0..self.client.tls_buffer_size];
        const socket_write_buffer = tls_write_buffer.ptr[tls_write_buffer.len..][0..self.client.write_buffer_size];
        const socket_read_buffer = socket_write_buffer.ptr[socket_write_buffer.len..][0..self.client.tls_buffer_size];
        @memcpy(host_buffer, remote_host.bytes);

        var tls: *LocalTlsConnection = @ptrCast(base);
        tls.connection = .{
            .client = &self.client,
            .stream_writer = stream.writer(self.client.io, tls_write_buffer),
            .stream_reader = stream.reader(self.client.io, socket_read_buffer),
            .pool_node = .{},
            .port = port,
            .host_len = @intCast(remote_host.bytes.len),
            .proxied = false,
            .closing = false,
            .protocol = .tls,
        };

        var guard = HttpDeadlineGuard.init(self.client.io, stream, null, req.aborted, req.timeout_ms, started_at_ns);
        try guard.start();
        defer guard.deinit();

        var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        self.client.io.random(&random_buffer);
        tls.client = std.crypto.tls.Client.init(
            &tls.connection.stream_reader.interface,
            &tls.connection.stream_writer.interface,
            .{
                .host = .{ .explicit = remote_host.bytes },
                .ca = .{ .bundle = .{
                    .gpa = self.client.allocator,
                    .io = self.client.io,
                    .lock = &self.client.ca_bundle_lock,
                    .bundle = &self.client.ca_bundle,
                } },
                .ssl_key_log = self.client.ssl_key_log,
                .read_buffer = tls_read_buffer,
                .write_buffer = socket_write_buffer,
                .entropy = &random_buffer,
                .realtime_now = self.client.now orelse std.Io.Clock.real.now(self.client.io),
                .allow_truncation_attacks = true,
            },
        ) catch |err| {
            try guard.check();
            return switch (err) {
                error.WriteFailed => tls.connection.stream_writer.err orelse HttpError.TlsFailure,
                error.ReadFailed => tls.connection.stream_reader.err orelse HttpError.TlsFailure,
                else => HttpError.TlsFailure,
            };
        };
        try guard.check();
        return &tls.connection;
    }

    fn initStreamingRequest(
        self: *HttpClient,
        request_ptr: *std.http.Client.Request,
        method: std.http.Method,
        current_uri: std.Uri,
        req: HttpRequest,
        request_started_at_ns: i128,
        redirect_behavior: std.http.Client.Request.RedirectBehavior,
        extra_headers: []std.http.Header,
    ) !void {
        const timeout_aware_connection = try self.openTimeoutAwareConnection(current_uri, req, request_started_at_ns);
        var request_adopted_timeout_aware_connection = false;
        errdefer if (!request_adopted_timeout_aware_connection) {
            self.releaseUnadoptedTimeoutAwareConnection(timeout_aware_connection);
        };

        if (builtin.is_test) {
            if (self.request_setup_failure_for_test) |err| return err;
        }

        request_ptr.* = try self.client.request(method, current_uri, .{
            .redirect_behavior = redirect_behavior,
            .extra_headers = extra_headers,
            .keep_alive = timeout_aware_connection == null,
            .connection = timeout_aware_connection,
        });
        request_adopted_timeout_aware_connection = true;
    }

    /// Send a request and return a streaming response for line-by-line reading.
    /// The caller must call streaming.deinit() when done.
    pub fn requestStreaming(self: *HttpClient, req: HttpRequest) anyerror!StreamingResponse {
        // Check abort signal before starting
        if (abort_helper.isRequested(req.aborted)) return HttpError.RequestAborted;
        const method = httpMethodFor(req.method);

        const uri = std.Uri.parse(req.url) catch return HttpError.InvalidUrl;

        const extra_headers_owned = try cloneRequestHeaders(self.allocator, req.headers);
        var owns_extra_headers = true;
        errdefer if (owns_extra_headers) self.allocator.free(extra_headers_owned);

        const manual_deadline_redirects = isDeadlineRequested(req) and req.body == null;
        const redirect_behavior: std.http.Client.Request.RedirectBehavior = if (manual_deadline_redirects or req.body != null) .unhandled else @enumFromInt(3);
        var redirect_buffer: []u8 = &[_]u8{};
        if (manual_deadline_redirects or redirect_behavior != .unhandled) {
            redirect_buffer = try self.allocator.alloc(u8, 8 * 1024);
        }
        var owns_redirect_buffer = true;
        errdefer if (owns_redirect_buffer and redirect_buffer.len > 0) self.allocator.free(redirect_buffer);

        var current_uri = uri;
        var redirect_aux_buffer = redirect_buffer;
        var redirects_remaining: u16 = 3;
        const request_started_at_ns = std.Io.Clock.now(.awake, self.client.io).nanoseconds;

        while (true) {
            var request_initialized = false;
            const request_ptr = try self.allocator.create(std.http.Client.Request);
            var owns_request = true;
            errdefer if (owns_request) {
                if (request_initialized) request_ptr.deinit();
                self.allocator.destroy(request_ptr);
            };

            // Start the deadline before connection acquisition. For numeric and
            // localhost/.localhost hosts with timeout/abort configured,
            // openTimeoutAwareConnection uses a repo-owned connect/TLS path so the
            // deadline covers connect and TLS handshake without touching
            // std.http.Client.Request from a watchdog thread. For other DNS names,
            // Zig 0.16's system resolver remains a documented limitation and we
            // keep std.http behavior, then charge elapsed budget once request()
            // returns.
            try self.initStreamingRequest(
                request_ptr,
                method,
                current_uri,
                req,
                request_started_at_ns,
                redirect_behavior,
                extra_headers_owned,
            );
            request_initialized = true;

            if (abort_helper.isRequested(req.aborted)) return HttpError.RequestAborted;
            if (hasDeadlineExpired(req.timeout_ms, request_started_at_ns, self.client.io)) return HttpError.Timeout;

            const shutdown_stream = request_ptr.connection.?.stream_reader.stream;
            var deadline_guard = HttpDeadlineGuard.init(self.client.io, shutdown_stream, request_ptr, req.aborted, req.timeout_ms, request_started_at_ns);
            try deadline_guard.start();
            var deadline_guard_active = true;
            defer if (deadline_guard_active) deadline_guard.deinit();

            try sendRequestWithDeadline(request_ptr, req.body, &deadline_guard);

            var response = request_ptr.receiveHead(redirect_buffer) catch |err| {
                try deadline_guard.check();
                return switch (err) {
                    error.TooManyHttpRedirects => HttpError.TooManyRedirects,
                    else => err,
                };
            };
            try deadline_guard.check();

            if (manual_deadline_redirects and response.head.status.class() == .redirect) {
                if (redirects_remaining == 0) return HttpError.TooManyRedirects;
                const location = response.head.location orelse return HttpError.InvalidUrl;
                if (location.len > redirect_aux_buffer.len) return HttpError.InvalidUrl;
                @memcpy(redirect_aux_buffer[0..location.len], location);
                current_uri = current_uri.resolveInPlace(location.len, &redirect_aux_buffer) catch return HttpError.InvalidUrl;
                redirects_remaining -= 1;

                deadline_guard.deinit();
                deadline_guard_active = false;
                request_ptr.deinit();
                self.allocator.destroy(request_ptr);
                owns_request = false;
                continue;
            }

            var response_headers = try cloneResponseHeaders(self.allocator, response.head);
            errdefer deinitOwnedHeaders(self.allocator, &response_headers);

            var streaming = StreamingResponse{
                .status = @intFromEnum(response.head.status),
                .body = &.{},
                .buffer = .empty,
                .allocator = self.allocator,
                .response_headers = response_headers,
                .owns_body = false,
                .request = request_ptr,
                .transfer_buffer = try self.allocator.alloc(u8, live_stream_transfer_buffer_bytes),
                .redirect_buffer = redirect_buffer,
                .extra_headers = extra_headers_owned,
                .deadline_guard = HttpDeadlineGuard.init(self.client.io, shutdown_stream, request_ptr, req.aborted, req.timeout_ms, request_started_at_ns),
            };
            errdefer streaming.deinit();
            owns_request = false;
            owns_extra_headers = false;
            owns_redirect_buffer = false;

            streaming.reader = switch (response.head.content_encoding) {
                .identity => response.reader(streaming.transfer_buffer),
                .zstd => blk: {
                    streaming.decompress_buffer = try self.allocator.alloc(u8, std.compress.zstd.default_window_len);
                    break :blk response.readerDecompressing(
                        streaming.transfer_buffer,
                        &streaming.decompress,
                        streaming.decompress_buffer,
                    );
                },
                .deflate, .gzip => blk: {
                    streaming.decompress_buffer = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
                    break :blk response.readerDecompressing(
                        streaming.transfer_buffer,
                        &streaming.decompress,
                        streaming.decompress_buffer,
                    );
                },
                .compress => return error.UnsupportedCompressionMethod,
            };

            return streaming;
        }
    }
};

fn statusCodeError(status_code: u16) ?HttpError {
    if (status_code >= 200 and status_code < 300) return null;
    if (status_code >= 300 and status_code < 400) return HttpError.UnexpectedRedirect;
    if (status_code >= 400 and status_code < 500) return HttpError.ClientError;
    if (status_code >= 500 and status_code < 600) return HttpError.ServerError;
    return null;
}

fn cloneResponseHeaders(
    allocator: std.mem.Allocator,
    head: std.http.Client.Response.Head,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &headers);

    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        try headers.put(
            try allocator.dupe(u8, header.name),
            try allocator.dupe(u8, header.value),
        );
    }

    return headers;
}

fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

test "HttpClient init/deinit" {
    var client = try HttpClient.init(std.testing.allocator, std.testing.io);
    client.deinit();
}

test "StreamingResponse readLine" {
    const allocator = std.testing.allocator;

    // Simulate a streaming response with SSE data
    const body = try allocator.dupe(u8, "data: hello\ndata: world\n\n");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    // Read lines
    const line1 = try stream.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("data: hello", line1.?);

    const line2 = try stream.readLine();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("data: world", line2.?);

    const line3 = try stream.readLine();
    try std.testing.expect(line3 != null);
    try std.testing.expectEqualStrings("", line3.?);

    const line4 = try stream.readLine();
    try std.testing.expect(line4 == null);
}

test "StreamingResponse readLine with \\r\\n" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "data: hello\r\ndata: world\r\n");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const line1 = try stream.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("data: hello", line1.?);

    const line2 = try stream.readLine();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("data: world", line2.?);
}

test "StreamingResponse readLine rejects oversized buffered line" {
    const allocator = std.testing.allocator;

    const body = try allocator.alloc(u8, max_stream_line_bytes + 1);
    @memset(body, 'a');

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    try std.testing.expectError(HttpError.StreamLineTooLong, stream.readLine());
    try std.testing.expect(stream.done);
    try std.testing.expect(stream.buffer.items.len <= max_stream_line_bytes);
}

test "StreamingResponse readLine accepts max sized buffered line and consumes delimiter" {
    const allocator = std.testing.allocator;

    const body = try allocator.alloc(u8, max_stream_line_bytes + "\nnext\n".len);
    @memset(body[0..max_stream_line_bytes], 'a');
    @memcpy(body[max_stream_line_bytes..], "\nnext\n");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const line1 = try stream.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqual(@as(usize, max_stream_line_bytes), line1.?.len);

    const line2 = try stream.readLine();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("next", line2.?);
}

test "HttpError codes exist" {
    // Just verify the error set compiles
    const err: HttpError = error.Timeout;
    try std.testing.expect(err == error.Timeout);
}

test "HttpRequest timeout and abort fields" {
    // Verify HttpRequest can be constructed with timeout and abort signal
    var abort_signal = std.atomic.Value(bool).init(false);

    const req = HttpRequest{
        .method = .POST,
        .url = "https://example.com",
        .timeout_ms = 5000,
        .aborted = &abort_signal,
    };

    try std.testing.expectEqual(@as(u32, 5000), req.timeout_ms);
    try std.testing.expect(req.aborted != null);
    try std.testing.expect(!abort_helper.isRequested(req.aborted));
}

test "StreamingResponse readAll" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "line1\nline2\nline3");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const all = try stream.readAll(allocator);
    defer allocator.free(all);

    try std.testing.expectEqualStrings("line1\nline2\nline3\n", all);
}

test "StreamingResponse readAllBounded caps buffered body" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "0123456789abcdef");

    var stream = StreamingResponse{
        .status = 500,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const bounded = try stream.readAllBounded(allocator, 6);
    defer allocator.free(bounded);

    try std.testing.expectEqualStrings("012345", bounded);
    try std.testing.expect(stream.done);
    try std.testing.expectEqual(@as(usize, 6), stream.pos);
}

test "StreamingResponse empty body" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const line1 = try stream.readLine();
    try std.testing.expect(line1 == null);
}

test "StreamingResponse single line no newline" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "just one line");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const line1 = try stream.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("just one line", line1.?);

    const line2 = try stream.readLine();
    try std.testing.expect(line2 == null);
}

const TestStreamingServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    status_code: u16,
    reason_phrase: []const u8,
    first_chunk: []const u8,
    second_chunk: []const u8,
    delay_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, first_chunk: []const u8, second_chunk: []const u8, delay_ms: u64) !TestStreamingServer {
        return initWithStatus(io, 200, "OK", first_chunk, second_chunk, delay_ms);
    }

    fn initWithStatus(
        io: std.Io,
        status_code: u16,
        reason_phrase: []const u8,
        first_chunk: []const u8,
        second_chunk: []const u8,
        delay_ms: u64,
    ) !TestStreamingServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .status_code = status_code,
            .reason_phrase = reason_phrase,
            .first_chunk = first_chunk,
            .second_chunk = second_chunk,
            .delay_ms = delay_ms,
        };
    }

    fn start(self: *TestStreamingServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestStreamingServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn port(self: *const TestStreamingServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn url(self: *const TestStreamingServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/stream", .{self.port()});
    }

    fn run(self: *TestStreamingServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("test server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(self, stream) catch |err| std.debug.panic("test server read failed: {}", .{err});
        writeResponse(self, stream) catch |err| std.debug.panic("test server write failed: {}", .{err});
    }

    fn readRequestHead(self: *TestStreamingServer, stream: std.Io.net.Stream) !void {
        _ = self;
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }

    fn writeResponse(self: *TestStreamingServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        const total_len = self.first_chunk.len + self.second_chunk.len;

        try writer.interface.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ self.status_code, self.reason_phrase, total_len },
        );
        try writer.interface.flush();

        if (self.first_chunk.len > 0) {
            try writer.interface.writeAll(self.first_chunk);
            try writer.interface.flush();
        }

        if (self.delay_ms > 0) {
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
        }

        if (self.second_chunk.len > 0) {
            writer.interface.writeAll(self.second_chunk) catch return;
            writer.interface.flush() catch return;
        }
    }
};

const TestPreHeaderStallServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    stall_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, stall_ms: u64) !TestPreHeaderStallServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .stall_ms = stall_ms,
        };
    }

    fn start(self: *TestPreHeaderStallServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestPreHeaderStallServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn port(self: *const TestPreHeaderStallServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn url(self: *const TestPreHeaderStallServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/stream", .{self.port()});
    }

    fn run(self: *TestPreHeaderStallServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled, error.ConnectionAborted => return,
            else => std.debug.panic("test server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(stream) catch return;
        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.stall_ms)), .awake) catch {};
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }
};

const TestRedirectServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    location: []const u8,
    old_connection_probe_delay_ms: u64,
    old_connection_probe_succeeded: *std.atomic.Value(bool),
    thread: ?std.Thread = null,

    fn init(
        io: std.Io,
        location: []const u8,
        old_connection_probe_delay_ms: u64,
        old_connection_probe_succeeded: *std.atomic.Value(bool),
    ) !TestRedirectServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .location = location,
            .old_connection_probe_delay_ms = old_connection_probe_delay_ms,
            .old_connection_probe_succeeded = old_connection_probe_succeeded,
        };
    }

    fn start(self: *TestRedirectServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestRedirectServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn port(self: *const TestRedirectServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn url(self: *const TestRedirectServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/redirect", .{self.port()});
    }

    fn run(self: *TestRedirectServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("test redirect server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        TestPreHeaderStallServer.readRequestHead(stream) catch return;
        writeRedirectAndProbeOldConnection(self, stream) catch return;
    }

    fn writeRedirectAndProbeOldConnection(self: *TestRedirectServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);

        try writer.interface.print(
            "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
            .{self.location},
        );
        try writer.interface.flush();

        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.old_connection_probe_delay_ms)), .awake) catch {};

        writer.interface.writeAll("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
        writer.interface.flush() catch return;
        self.old_connection_probe_succeeded.store(true, .seq_cst);
    }
};

fn expectOldConnectionProbeSucceeded(io: std.Io, succeeded: *std.atomic.Value(bool)) !void {
    const deadline_ns = std.Io.Clock.now(.awake, io).nanoseconds + 2 * std.time.ns_per_s;
    while (!succeeded.load(.seq_cst) and std.Io.Clock.now(.awake, io).nanoseconds < deadline_ns) {
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(succeeded.load(.seq_cst));
}

const TestTlsHandshakeStallServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    stall_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, stall_ms: u64) !TestTlsHandshakeStallServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .stall_ms = stall_ms,
        };
    }

    fn start(self: *TestTlsHandshakeStallServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestTlsHandshakeStallServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn port(self: *const TestTlsHandshakeStallServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn url(self: *const TestTlsHandshakeStallServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://127.0.0.1:{d}/stream", .{self.port()});
    }

    fn run(self: *TestTlsHandshakeStallServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("test TLS stall server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.stall_ms)), .awake) catch {};
    }
};

const TestAcceptOnlyServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    hold_ms: u64,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn init(io: std.Io, hold_ms: u64) !TestAcceptOnlyServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .hold_ms = hold_ms,
        };
    }

    fn start(self: *TestAcceptOnlyServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestAcceptOnlyServer) void {
        self.stopping.store(true, .release);
        if (self.thread) |thread| {
            self.wakeAccept();
            thread.join();
        }
        self.server.deinit(self.io);
    }

    fn port(self: *const TestAcceptOnlyServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn run(self: *TestAcceptOnlyServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled, error.ConnectionAborted => return,
            else => std.debug.panic("test accept-only server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);
        if (self.stopping.load(.acquire)) return;
        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.hold_ms)), .awake) catch {};
    }

    fn wakeAccept(self: *TestAcceptOnlyServer) void {
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        const stream = address.connect(self.io, .{ .mode = .stream }) catch return;
        stream.close(self.io);
    }
};

test "request returns connection refused for unreachable endpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var listener = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/missing", .{port});
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
    });

    try std.testing.expectError(HttpError.ConnectionRefused, response);
}

test "request returns client error for 4xx responses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.initWithStatus(io, 404, "Not Found", "missing", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
    });

    try std.testing.expectError(HttpError.ClientError, response);
}

test "request returns server error for 5xx responses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.initWithStatus(io, 503, "Service Unavailable", "down", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
    });

    try std.testing.expectError(HttpError.ServerError, response);
}

test "POSIX timeout-aware connect returns a blocking stream" {
    if (!supports_posix_active_connect_deadline) return error.SkipZigTest;

    const io = std.testing.io;
    var server = try TestAcceptOnlyServer.init(io, 50);
    defer server.deinit();
    try server.start();

    const started_at_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(server.port()) };
    const stream = try connectTcpDeadlinePosix(address, .{
        .method = .GET,
        .url = "http://127.0.0.1/",
        .timeout_ms = 1_000,
    }, started_at_ns, io);
    defer stream.close(io);

    try std.testing.expect(!try socketIsNonblockingPosix(stream.socket.handle));
}

test "requestStreaming returns connection refused for timeout-aware numeric endpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var listener = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/missing", .{port});
    defer allocator.free(url);

    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 1_000,
    });

    try std.testing.expectError(HttpError.ConnectionRefused, streaming);
}

test "requestStreaming releases timeout-aware connection when setup fails before adoption" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestAcceptOnlyServer.init(io, 50);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();
    client.request_setup_failure_for_test = error.RequestSetupFailedForTest;

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/setup-failure", .{server.port()});
    defer allocator.free(url);

    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 1_000,
    });

    try std.testing.expectError(error.RequestSetupFailedForTest, streaming);
    try std.testing.expectEqual(@as(?*std.DoublyLinkedList.Node, null), client.client.connection_pool.used.first);
    try std.testing.expectEqual(@as(?*std.DoublyLinkedList.Node, null), client.client.connection_pool.free.first);
    try std.testing.expectEqual(@as(usize, 0), client.client.connection_pool.free_len);
}

test "requestStreaming transfers timeout-aware connection ownership after adoption" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: adopted\n\n", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 1_000,
    });

    try std.testing.expect(client.client.connection_pool.used.first != null);
    streaming.deinit();
    try std.testing.expectEqual(@as(?*std.DoublyLinkedList.Node, null), client.client.connection_pool.used.first);
    try std.testing.expectEqual(@as(?*std.DoublyLinkedList.Node, null), client.client.connection_pool.free.first);
    try std.testing.expectEqual(@as(usize, 0), client.client.connection_pool.free_len);
}

test "request rejects oversized non-streaming response body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.initWithStatus(io, 200, "OK", "0123456789abcdef", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
        .max_response_body_bytes = 8,
    });

    try std.testing.expectError(HttpError.ResponseBodyTooLarge, response);
}

test "request times out while waiting for response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestPreHeaderStallServer.init(io, 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const response = client.request(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, response);
    try std.testing.expect(elapsed_ms < server.stall_ms);
}

test "request aborts while waiting for response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestPreHeaderStallServer.init(io, 500);
    defer server.deinit();
    try server.start();

    var abort_signal = std.atomic.Value(bool).init(false);
    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const response = client.request(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.RequestAborted, response);
    try std.testing.expect(elapsed_ms < server.stall_ms);
}

test "request times out while waiting for response body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "", "delayed-body", 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const response = client.request(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, response);
    try std.testing.expect(elapsed_ms < server.delay_ms);
}

test "request aborts while waiting for response body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "", "delayed-body", 500);
    defer server.deinit();
    try server.start();

    var abort_signal = std.atomic.Value(bool).init(false);
    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const response = client.request(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.RequestAborted, response);
    try std.testing.expect(elapsed_ms < server.delay_ms);
}

test "request honors already aborted signal before connecting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var listener = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    var abort_signal = std.atomic.Value(bool).init(true);
    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/missing", .{port});
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });

    try std.testing.expectError(HttpError.RequestAborted, response);
}

test "requestStreaming times out before the first line arrives" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "", "data: delayed\n", 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    defer streaming.deinit();

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const line = streaming.readLine();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, line);
    try std.testing.expect(elapsed_ms < server.delay_ms);
}

test "requestStreaming readLine rejects oversized live line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const oversized_line = try allocator.alloc(u8, max_stream_line_bytes + 1);
    defer allocator.free(oversized_line);
    @memset(oversized_line, 'b');

    var server = try TestStreamingServer.init(io, oversized_line, "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
    });
    defer streaming.deinit();

    try std.testing.expectError(HttpError.StreamLineTooLong, streaming.readLine());
    try std.testing.expect(streaming.done);
    try std.testing.expect(streaming.buffer.items.len <= max_stream_line_bytes);
}

test "requestStreaming readLine accepts max sized live line independent of transfer buffer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const response_body = try allocator.alloc(u8, max_stream_line_bytes + "\nnext\n".len);
    defer allocator.free(response_body);
    @memset(response_body[0..max_stream_line_bytes], 'c');
    @memcpy(response_body[max_stream_line_bytes..], "\nnext\n");

    var server = try TestStreamingServer.init(io, response_body, "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
    });
    defer streaming.deinit();

    try std.testing.expect(streaming.transfer_buffer.len > 64);
    try std.testing.expect(streaming.transfer_buffer.len < max_stream_line_bytes);
    try std.testing.expectEqual(@as(usize, live_stream_transfer_buffer_bytes), streaming.transfer_buffer.len);

    const line1 = try streaming.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqual(@as(usize, max_stream_line_bytes), line1.?.len);

    const line2 = try streaming.readLine();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("next", line2.?);
}

test "requestStreaming times out while waiting for response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestPreHeaderStallServer.init(io, 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, streaming);
    try std.testing.expect(elapsed_ms < server.stall_ms);
}

test "requestStreaming timeout interrupts redirected response header stall without closing old connection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var target_server = try TestPreHeaderStallServer.init(io, 500);
    defer target_server.deinit();
    try target_server.start();

    const target_url = try target_server.url(allocator);
    defer allocator.free(target_url);

    var old_connection_probe_succeeded = std.atomic.Value(bool).init(false);
    var redirect_server = try TestRedirectServer.init(io, target_url, 250, &old_connection_probe_succeeded);
    defer redirect_server.deinit();
    try redirect_server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try redirect_server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, streaming);
    try std.testing.expect(elapsed_ms < target_server.stall_ms);

    try expectOldConnectionProbeSucceeded(io, &old_connection_probe_succeeded);
}

test "requestStreaming uses timeout-aware localhost connection path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: local\n", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/stream", .{server.port()});
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 1_000,
    });
    defer streaming.deinit();

    const line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: local", line);
}

test "requestStreaming uses timeout-aware .localhost test connection path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: test-local\n", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://pi-timeout.localhost:{d}/stream", .{server.port()});
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 1_000,
    });
    defer streaming.deinit();

    const line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: test-local", line);
}

test "requestStreaming aborts while waiting for response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestPreHeaderStallServer.init(io, 500);
    defer server.deinit();
    try server.start();

    var abort_signal = std.atomic.Value(bool).init(false);
    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.RequestAborted, streaming);
    try std.testing.expect(elapsed_ms < server.stall_ms);
}

test "requestStreaming abort interrupts redirected response header stall without closing old connection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var target_server = try TestPreHeaderStallServer.init(io, 500);
    defer target_server.deinit();
    try target_server.start();

    const target_url = try target_server.url(allocator);
    defer allocator.free(target_url);

    var old_connection_probe_succeeded = std.atomic.Value(bool).init(false);
    var redirect_server = try TestRedirectServer.init(io, target_url, 250, &old_connection_probe_succeeded);
    defer redirect_server.deinit();
    try redirect_server.start();

    var abort_signal = std.atomic.Value(bool).init(false);
    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try redirect_server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.RequestAborted, streaming);
    try std.testing.expect(elapsed_ms < target_server.stall_ms);

    try expectOldConnectionProbeSucceeded(io, &old_connection_probe_succeeded);
}

test "requestStreaming times out during TLS handshake stall" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestTlsHandshakeStallServer.init(io, 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, streaming);
    try std.testing.expect(elapsed_ms < server.stall_ms);
}

test "requestStreaming aborts during TLS handshake stall" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestTlsHandshakeStallServer.init(io, 500);
    defer server.deinit();
    try server.start();

    var abort_signal = std.atomic.Value(bool).init(false);
    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const streaming = client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.RequestAborted, streaming);
    try std.testing.expect(elapsed_ms < server.stall_ms);
}

test "requestStreaming returns before full response body is available" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: first\n", "data: second\n", 250);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
    });
    defer streaming.deinit();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expect(elapsed_ms < server.delay_ms);

    const first_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: first", first_line);

    const second_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: second", second_line);
}

test "requestStreaming aborts while waiting for the next line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: first\n", "data: second\n", 500);
    defer server.deinit();
    try server.start();

    var abort_signal = std.atomic.Value(bool).init(false);

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });
    defer streaming.deinit();

    const first_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: first", first_line);

    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const next_line = streaming.readLine();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.RequestAborted, next_line);
    try std.testing.expect(elapsed_ms < server.delay_ms);
}

test "requestStreaming enforces timeout while waiting for the next line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: first\n", "data: second\n", 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    defer streaming.deinit();

    const first_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: first", first_line);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const next_line = streaming.readLine();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, next_line);
    try std.testing.expect(elapsed_ms < server.delay_ms);
}

test "requestStreaming abort signal" {
    const allocator = std.testing.allocator;

    var abort_signal = std.atomic.Value(bool).init(true);

    var client = try HttpClient.init(allocator, std.testing.io);
    defer client.deinit();

    const req = HttpRequest{
        .method = .GET,
        .url = "https://example.com",
        .aborted = &abort_signal,
    };

    const result = client.requestStreaming(req);
    try std.testing.expectError(HttpError.RequestAborted, result);
}
