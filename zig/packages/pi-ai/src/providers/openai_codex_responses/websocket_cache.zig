const std = @import("std");
const websocket_client = @import("../../websocket_client.zig");
const provider_json = @import("../../shared/provider_json.zig");

// ============================================================================
// WebSocket -> SSE Fallback Registry (port of TS PR #4133)
// ============================================================================
//
// Per-process registry of session_ids whose WebSocket connection failed with a
// transport-class error. Subsequent `transport: .auto` calls with the same
// session_id skip the WebSocket attempt and go straight to SSE. This mirrors
// `websocketSseFallbackSessions` in `packages/ai/src/providers/openai-codex-responses.ts`.
//
// Application/protocol errors from the Codex server (`response.failed`, top
// level `error` JSON events) are classified as non-transport errors and do
// NOT populate the registry — they propagate as terminal error_events on the
// stream so callers can retry the same transport.

const WebSocketFallbackRegistry = struct {
    var mutex: std.Io.Mutex = .init;
    var initialized: bool = false;
    var sessions: std.StringHashMap(void) = undefined;

    fn ensureInitialized() void {
        if (!initialized) {
            sessions = std.StringHashMap(void).init(std.heap.page_allocator);
            initialized = true;
        }
    }

    fn isActiveLocked(session_id: []const u8) bool {
        ensureInitialized();
        return sessions.contains(session_id);
    }

    fn recordLocked(session_id: []const u8) !void {
        ensureInitialized();
        if (sessions.contains(session_id)) return;
        const owned = try std.heap.page_allocator.dupe(u8, session_id);
        errdefer std.heap.page_allocator.free(owned);
        try sessions.put(owned, {});
    }

    fn clearLocked(session_id: ?[]const u8) void {
        ensureInitialized();
        if (session_id) |id| {
            if (sessions.fetchRemove(id)) |removed| {
                std.heap.page_allocator.free(removed.key);
            }
        } else {
            var iterator = sessions.iterator();
            while (iterator.next()) |entry| {
                std.heap.page_allocator.free(entry.key_ptr.*);
            }
            sessions.clearRetainingCapacity();
        }
    }
};

/// Returns true when a previous WebSocket attempt for this `session_id`
/// failed with a transport-class error and `transport: .auto` callers should
/// skip the WebSocket attempt.
pub fn isWebSocketSseFallbackActive(session_id: ?[]const u8, io: std.Io) bool {
    const id = session_id orelse return false;
    if (id.len == 0) return false;
    WebSocketFallbackRegistry.mutex.lockUncancelable(io);
    defer WebSocketFallbackRegistry.mutex.unlock(io);
    return WebSocketFallbackRegistry.isActiveLocked(id);
}

/// Marks `session_id` as having experienced a WebSocket transport failure.
/// Subsequent `transport: .auto` calls for the same session will skip the
/// WebSocket attempt and use SSE directly. Best-effort: OOM is swallowed
/// because the SSE fallback can still proceed without the registry entry.
pub fn recordWebSocketFailure(session_id: ?[]const u8, io: std.Io) void {
    const id = session_id orelse return;
    if (id.len == 0) return;
    WebSocketFallbackRegistry.mutex.lockUncancelable(io);
    defer WebSocketFallbackRegistry.mutex.unlock(io);
    WebSocketFallbackRegistry.recordLocked(id) catch {};
}

/// Removes `session_id` from the registry. Pass null to clear all entries.
/// Used by tests; mirrors `resetOpenAICodexWebSocketDebugStats`.
pub fn resetWebSocketFallbackRegistry(session_id: ?[]const u8, io: std.Io) void {
    WebSocketFallbackRegistry.mutex.lockUncancelable(io);
    defer WebSocketFallbackRegistry.mutex.unlock(io);
    WebSocketFallbackRegistry.clearLocked(session_id);
}

/// Classify a setup/transport error as a Codex non-transport error.
/// Mirrors TS `isCodexNonTransportError`: returns true for protocol/API
/// errors that should NOT trigger SSE fallback (`response.failed`,
/// top-level `error` JSON events arrive via `error.CodexApiError` /
/// `error.CodexProtocolError`). Returns false for WebSocket transport
/// errors (handshake, frame, TLS, connection close, etc.).
pub fn isCodexNonTransportError(err: anyerror) bool {
    return switch (err) {
        error.CodexApiError, error.CodexProtocolError => true,
        else => false,
    };
}

// ============================================================================
// WebSocket Connection Cache (port of TS `websocketSessionCache`)
// ============================================================================
//
// Per-process cache keyed by session_id. Each entry owns a live
// `websocket_client.Client` plus a `continuation` snapshot describing the
// last accepted request body and the items the server returned, so that the
// next compatible call can rewrite its request as
// `{ ...body, previous_response_id, input: delta }` and reuse the socket.
//
// Lifetime / TTL:
//   * 5-minute idle TTL. Stale entries are dropped lazily on the next
//     `acquire` call — there is no background thread.
//   * `busy` flag: only one in-flight call may use the cached socket at a
//     time. Parallel callers with cache hit + busy fall through to a fresh
//     uncached single-shot connection.
//
// Continuation match contract (mirrors TS
// `buildCachedWebSocketRequestBody`):
//   * Non-input fields of the new request must equal the prior request's
//     (stable JSON round-trip comparison modulo `input` and
//     `previous_response_id`).
//   * The new `input` array must be a prefix-extension of
//     `prior_input ++ prior_response_items` (deep equal).
//   * `function_call_output` items from the assistant's prior response are
//     filtered out — the server expects the caller to re-send tool results
//     as part of the delta `input`.
//
// Time source is abstracted via `time_source_ns` so tests can advance the
// TTL clock without spinning real time.

pub const SESSION_WEBSOCKET_CACHE_TTL_NS: i128 =
    @as(i128, 5) * std.time.ns_per_min;

/// Read the wall-clock time used for cache TTL comparisons. Tests may
/// override this by setting `WebSocketConnectionCache.test_now_override`.
fn currentTimeNs(io: std.Io) i128 {
    if (WebSocketConnectionCache.test_now_override) |t| return t;
    return std.Io.Clock.real.now(io).nanoseconds;
}

pub const Continuation = struct {
    last_request_body: std.json.Value,
    last_response_id: []u8,
    last_response_items: std.json.Array,

    pub fn deinit(self: *Continuation, allocator: std.mem.Allocator) void {
        provider_json.freeValue(allocator, self.last_request_body);
        allocator.free(self.last_response_id);
        provider_json.freeValue(allocator, .{ .array = self.last_response_items });
    }
};

pub const Entry = struct {
    allocator: std.mem.Allocator,
    client: *websocket_client.Client,
    busy: bool,
    last_used_ns: i128,
    continuation: ?Continuation = null,

    fn deinit(self: *Entry) void {
        if (self.continuation) |*continuation| continuation.deinit(self.allocator);
        self.client.deinit();
        self.allocator.destroy(self.client);
    }
};

const WebSocketConnectionCache = struct {
    var mutex: std.Io.Mutex = .init;
    var initialized: bool = false;
    var entries: std.StringHashMap(*Entry) = undefined;
    /// Test-only clock override. When non-null, replaces the wall clock
    /// reading used for entry timestamps and expiry comparisons.
    var test_now_override: ?i128 = null;

    fn ensureInitialized() void {
        if (!initialized) {
            entries = std.StringHashMap(*Entry).init(std.heap.page_allocator);
            initialized = true;
        }
    }

    fn isExpiredAt(entry: *const Entry, now_ns: i128) bool {
        return (now_ns - entry.last_used_ns) >= SESSION_WEBSOCKET_CACHE_TTL_NS;
    }

    fn discardEntryLocked(session_id: []const u8, entry: *Entry) void {
        if (entries.fetchRemove(session_id)) |removed| {
            std.heap.page_allocator.free(removed.key);
        }
        entry.deinit();
        std.heap.page_allocator.destroy(entry);
    }
};

/// Override the cache's wall clock for tests. Pass `null` to restore the
/// real-time clock.
pub fn setWebSocketCacheNowOverrideForTesting(now_ns: ?i128, io: std.Io) void {
    WebSocketConnectionCache.mutex.lockUncancelable(io);
    defer WebSocketConnectionCache.mutex.unlock(io);
    WebSocketConnectionCache.test_now_override = now_ns;
}

/// Test-only inspector — returns true iff the cache currently holds an
/// entry for `session_id` (regardless of busy/idle state).
pub fn hasCachedWebSocketSessionForTesting(session_id: []const u8, io: std.Io) bool {
    WebSocketConnectionCache.mutex.lockUncancelable(io);
    defer WebSocketConnectionCache.mutex.unlock(io);
    WebSocketConnectionCache.ensureInitialized();
    return WebSocketConnectionCache.entries.contains(session_id);
}

/// Closes the cached WebSocket connection for `session_id` (or all of them
/// if `null`). Mirrors TS `closeOpenAICodexWebSocketSessions`. Safe to call
/// at session-end as a cleanup hook.
pub fn closeOpenAICodexWebSocketSessions(session_id: ?[]const u8, io: std.Io) void {
    WebSocketConnectionCache.mutex.lockUncancelable(io);
    defer WebSocketConnectionCache.mutex.unlock(io);
    WebSocketConnectionCache.ensureInitialized();

    if (session_id) |id| {
        if (WebSocketConnectionCache.entries.get(id)) |entry| {
            WebSocketConnectionCache.discardEntryLocked(id, entry);
        }
        return;
    }

    // Close all. Collect keys first because we mutate the map during
    // iteration via discardEntryLocked.
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(std.heap.page_allocator);
    var iterator = WebSocketConnectionCache.entries.iterator();
    while (iterator.next()) |entry| {
        keys.append(std.heap.page_allocator, entry.key_ptr.*) catch return;
    }
    for (keys.items) |key| {
        if (WebSocketConnectionCache.entries.get(key)) |entry| {
            WebSocketConnectionCache.discardEntryLocked(key, entry);
        }
    }
}

const CacheAcquireResult = struct {
    entry: *Entry,
    /// True when the entry was already present and reusable. Callers should
    /// rewrite the request body via `buildCachedWebSocketRequestBody` when
    /// `reused` is true and the entry has a continuation.
    reused: bool,
};

pub const BusyState = enum { free, busy_skip, fresh };

/// Inspects the cache for `session_id` without taking ownership. Returns:
///   * `.free`     — an idle reusable entry is available; caller should
///                   open/use it via `acquireCachedConnection`.
///   * `.busy_skip` — an entry exists but is busy; caller must open a
///                   fresh single-shot uncached connection (not stored).
///   * `.fresh`    — no entry; caller should open a new cached connection.
pub fn peekCacheBusyState(session_id: []const u8, io: std.Io) BusyState {
    const now = currentTimeNs(io);
    WebSocketConnectionCache.mutex.lockUncancelable(io);
    defer WebSocketConnectionCache.mutex.unlock(io);
    WebSocketConnectionCache.ensureInitialized();

    const entry = WebSocketConnectionCache.entries.get(session_id) orelse return .fresh;
    if (WebSocketConnectionCache.isExpiredAt(entry, now)) {
        WebSocketConnectionCache.discardEntryLocked(session_id, entry);
        return .fresh;
    }
    if (entry.busy) return .busy_skip;
    return .free;
}

/// Marks an existing idle entry as busy and returns it. Returns null if
/// the entry has disappeared or expired between `peekCacheBusyState` and
/// here, in which case the caller should fall through to a fresh connect.
pub fn acquireExistingEntry(session_id: []const u8, io: std.Io) ?*Entry {
    const now = currentTimeNs(io);
    WebSocketConnectionCache.mutex.lockUncancelable(io);
    defer WebSocketConnectionCache.mutex.unlock(io);
    WebSocketConnectionCache.ensureInitialized();

    const entry = WebSocketConnectionCache.entries.get(session_id) orelse return null;
    if (WebSocketConnectionCache.isExpiredAt(entry, now)) {
        WebSocketConnectionCache.discardEntryLocked(session_id, entry);
        return null;
    }
    if (entry.busy) return null;
    entry.busy = true;
    return entry;
}

/// Installs a freshly-opened client as the cached entry for `session_id`,
/// transferring ownership of the heap-allocated client. The caller must
/// not deinit / destroy the client after this call.
pub fn installCacheEntry(
    session_id: []const u8,
    client_ptr: *websocket_client.Client,
    io: std.Io,
) error{OutOfMemory}!*Entry {
    const now = currentTimeNs(io);
    WebSocketConnectionCache.mutex.lockUncancelable(io);
    defer WebSocketConnectionCache.mutex.unlock(io);
    WebSocketConnectionCache.ensureInitialized();

    // If a stale entry exists for the same session id, evict it first.
    if (WebSocketConnectionCache.entries.get(session_id)) |existing| {
        WebSocketConnectionCache.discardEntryLocked(session_id, existing);
    }

    const entry = try std.heap.page_allocator.create(Entry);
    errdefer std.heap.page_allocator.destroy(entry);
    entry.* = .{
        .allocator = std.heap.page_allocator,
        .client = client_ptr,
        .busy = true,
        .last_used_ns = now,
        .continuation = null,
    };

    const key_owned = try std.heap.page_allocator.dupe(u8, session_id);
    errdefer std.heap.page_allocator.free(key_owned);
    try WebSocketConnectionCache.entries.put(key_owned, entry);
    return entry;
}

/// Releases a cache entry. If `keep_alive` is false the entry is closed
/// and removed; otherwise its `busy` flag is cleared and `last_used_ns`
/// is refreshed so the idle TTL starts over.
pub fn releaseCacheEntry(session_id: []const u8, entry: *Entry, keep_alive: bool, io: std.Io) void {
    const now = currentTimeNs(io);
    WebSocketConnectionCache.mutex.lockUncancelable(io);
    defer WebSocketConnectionCache.mutex.unlock(io);
    WebSocketConnectionCache.ensureInitialized();

    if (!keep_alive) {
        // Only evict if the entry is still the one cached for this session.
        if (WebSocketConnectionCache.entries.get(session_id)) |current| {
            if (current == entry) {
                WebSocketConnectionCache.discardEntryLocked(session_id, entry);
                return;
            }
        }
        // Entry was already evicted; just deinit it.
        entry.deinit();
        std.heap.page_allocator.destroy(entry);
        return;
    }

    entry.busy = false;
    entry.last_used_ns = now;
}

/// Replaces the continuation snapshot for an entry currently in our hand
/// (i.e. busy). Frees any prior continuation.
pub fn setEntryContinuation(
    entry: *Entry,
    request_body: std.json.Value,
    response_id: []u8,
    response_items: std.json.Array,
) void {
    if (entry.continuation) |*existing| existing.deinit(entry.allocator);
    entry.continuation = .{
        .last_request_body = request_body,
        .last_response_id = response_id,
        .last_response_items = response_items,
    };
}

pub fn clearEntryContinuation(entry: *Entry) void {
    if (entry.continuation) |*existing| existing.deinit(entry.allocator);
    entry.continuation = null;
}

// --- Body equality / prefix-extension ---------------------------------------

/// Returns a JSON value equal to `body` but with `input` and
/// `previous_response_id` stripped. Allocated owned values out of
/// `allocator` (release via `provider_json.freeValue`).
fn cloneBodyWithoutInput(allocator: std.mem.Allocator, body: std.json.Value) !std.json.Value {
    if (body != .object) return try provider_json.cloneValue(allocator, body);
    var cloned = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = cloned });
    var iterator = body.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "input") or std.mem.eql(u8, key, "previous_response_id")) continue;
        const cloned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(cloned_key);
        const cloned_value = try provider_json.cloneValue(allocator, entry.value_ptr.*);
        errdefer provider_json.freeValue(allocator, cloned_value);
        try cloned.put(allocator, cloned_key, cloned_value);
    }
    return .{ .object = cloned };
}

fn bodiesMatchExceptInput(
    allocator: std.mem.Allocator,
    a: std.json.Value,
    b: std.json.Value,
) !bool {
    const a_stripped = try cloneBodyWithoutInput(allocator, a);
    defer provider_json.freeValue(allocator, a_stripped);
    const b_stripped = try cloneBodyWithoutInput(allocator, b);
    defer provider_json.freeValue(allocator, b_stripped);

    const a_json = try std.json.Stringify.valueAlloc(allocator, a_stripped, .{});
    defer allocator.free(a_json);
    const b_json = try std.json.Stringify.valueAlloc(allocator, b_stripped, .{});
    defer allocator.free(b_json);
    return std.mem.eql(u8, a_json, b_json);
}

fn responseInputItemsEqual(
    allocator: std.mem.Allocator,
    a: std.json.Value,
    b: std.json.Value,
) !bool {
    const a_json = try std.json.Stringify.valueAlloc(allocator, a, .{});
    defer allocator.free(a_json);
    const b_json = try std.json.Stringify.valueAlloc(allocator, b, .{});
    defer allocator.free(b_json);
    return std.mem.eql(u8, a_json, b_json);
}

const CachedDeltaResult = union(enum) {
    /// Body is incompatible with the prior continuation; caller must send
    /// the full request body as-is.
    no_match,
    /// Body matches; caller must send a rewritten request with
    /// `previous_response_id` set and `input` replaced by `delta_items`.
    /// `delta_items` is owned by the caller.
    matched: struct {
        previous_response_id: []u8,
        delta_items: std.json.Array,
    },
};

/// Computes the cached-request delta against `continuation`. Returns
/// `.matched` only when the request bodies match modulo `input` and the
/// new `input` is a prefix-extension of `prior_input ++ prior_response_items`.
fn computeCachedDelta(
    allocator: std.mem.Allocator,
    body: std.json.Value,
    continuation: Continuation,
) !CachedDeltaResult {
    if (body != .object) return .no_match;
    if (!try bodiesMatchExceptInput(allocator, body, continuation.last_request_body)) return .no_match;

    const current_input_value = body.object.get("input") orelse return .no_match;
    if (current_input_value != .array) return .no_match;
    const current_input = current_input_value.array;

    // Baseline = prior_input ++ prior_response_items
    var baseline = std.json.Array.init(allocator);
    defer baseline.deinit();
    const prior_input_value = continuation.last_request_body.object.get("input");
    if (prior_input_value) |val| {
        if (val == .array) {
            for (val.array.items) |item| try baseline.append(item);
        }
    }
    for (continuation.last_response_items.items) |item| try baseline.append(item);

    if (current_input.items.len < baseline.items.len) return .no_match;

    // Prefix equality via JSON serialization on each item.
    for (baseline.items, 0..) |baseline_item, idx| {
        const current_item = current_input.items[idx];
        if (!try responseInputItemsEqual(allocator, baseline_item, current_item)) return .no_match;
    }

    var delta_items = std.json.Array.init(allocator);
    errdefer {
        for (delta_items.items) |item| provider_json.freeValue(allocator, item);
        delta_items.deinit();
    }
    for (current_input.items[baseline.items.len..]) |item| {
        try delta_items.append(try provider_json.cloneValue(allocator, item));
    }

    const previous_response_id = try allocator.dupe(u8, continuation.last_response_id);
    return .{ .matched = .{
        .previous_response_id = previous_response_id,
        .delta_items = delta_items,
    } };
}

/// If `entry.continuation` is set and the body is a compatible prefix
/// extension, returns a new request body where `input` is the delta and
/// `previous_response_id` is set. Otherwise clears the continuation and
/// returns null (caller sends `body` unmodified). Caller owns the returned
/// value (release via `provider_json.freeValue`).
pub fn buildCachedWebSocketRequestBody(
    allocator: std.mem.Allocator,
    entry: *Entry,
    body: std.json.Value,
) !?std.json.Value {
    const continuation = entry.continuation orelse return null;
    if (continuation.last_response_id.len == 0) {
        clearEntryContinuation(entry);
        return null;
    }
    const delta = try computeCachedDelta(allocator, body, continuation);
    if (delta == .no_match) {
        clearEntryContinuation(entry);
        return null;
    }

    // `delta.matched.previous_response_id` and `delta.matched.delta_items`
    // are owned here. We move them into `cloned` below; on any failure
    // before the move we must free them.
    var prev_id_owned: ?[]u8 = delta.matched.previous_response_id;
    var delta_items_owned: ?std.json.Array = delta.matched.delta_items;
    errdefer {
        if (prev_id_owned) |id| allocator.free(id);
        if (delta_items_owned) |items| {
            for (items.items) |item| provider_json.freeValue(allocator, item);
            var mutable = items;
            mutable.deinit();
        }
    }

    // Build {...body, previous_response_id, input: delta_items}.
    var cloned = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = cloned });

    var iterator = body.object.iterator();
    while (iterator.next()) |kv| {
        const key = kv.key_ptr.*;
        if (std.mem.eql(u8, key, "input") or std.mem.eql(u8, key, "previous_response_id")) continue;
        const cloned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(cloned_key);
        const cloned_value = try provider_json.cloneValue(allocator, kv.value_ptr.*);
        errdefer provider_json.freeValue(allocator, cloned_value);
        try cloned.put(allocator, cloned_key, cloned_value);
    }

    const prev_key = try allocator.dupe(u8, "previous_response_id");
    errdefer allocator.free(prev_key);
    try cloned.put(allocator, prev_key, .{ .string = prev_id_owned.? });
    prev_id_owned = null; // ownership moved into `cloned`

    const input_key = try allocator.dupe(u8, "input");
    errdefer allocator.free(input_key);
    try cloned.put(allocator, input_key, .{ .array = delta_items_owned.? });
    delta_items_owned = null; // ownership moved into `cloned`

    return .{ .object = cloned };
}
