const std = @import("std");
const fuzzy = @import("shared").fuzzy;

pub const SessionSearchInfo = struct {
    path: []const u8,
    id: []const u8,
    cwd: []const u8,
    name: ?[]const u8 = null,
    parent_session: ?[]const u8 = null,
    created_timestamp: []const u8,
    modified_timestamp: []const u8,
    message_count: usize,
    first_message: []const u8,
    all_messages_text: []const u8,
    search_text: []const u8,

    pub fn deinit(self: *SessionSearchInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.id);
        allocator.free(self.cwd);
        if (self.name) |name| allocator.free(name);
        if (self.parent_session) |parent_session| allocator.free(parent_session);
        allocator.free(self.created_timestamp);
        allocator.free(self.modified_timestamp);
        allocator.free(self.first_message);
        allocator.free(self.all_messages_text);
        allocator.free(self.search_text);
        self.* = undefined;
    }
};

pub const SessionSearchSortMode = enum {
    recent,
    relevance,
};

pub const SessionSearchNameFilter = enum {
    all,
    named,
};

pub const SessionSearchField = enum {
    any,
    name,
    content,
    cwd,
    id,
};

pub const SessionSearchTokenKind = enum {
    fuzzy,
    phrase,
};

pub const SessionSearchToken = struct {
    field: SessionSearchField = .any,
    kind: SessionSearchTokenKind,
    value: []const u8,
};

pub const SessionSearchQueryMode = enum {
    tokens,
    regex,
};

pub const ParsedSessionSearchQuery = struct {
    mode: SessionSearchQueryMode = .tokens,
    tokens: []const SessionSearchToken,
    regex_pattern: []const u8 = "",
    regex_valid: bool = true,

    pub fn deinit(self: *ParsedSessionSearchQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        self.* = .{
            .tokens = &.{},
        };
    }
};

pub const SessionSearchMatch = struct {
    session_index: usize,
    score: i32,
};

pub const SessionSearchOptions = struct {
    sort_mode: SessionSearchSortMode = .relevance,
    name_filter: SessionSearchNameFilter = .all,
};

pub const SessionSearchResults = struct {
    sessions: []const SessionSearchInfo,
    matches: []const SessionSearchMatch,

    pub fn deinit(self: *SessionSearchResults, allocator: std.mem.Allocator) void {
        for (@constCast(self.sessions)) |*session| session.deinit(allocator);
        allocator.free(@constCast(self.sessions));
        allocator.free(@constCast(self.matches));
        self.* = .{
            .sessions = &.{},
            .matches = &.{},
        };
    }
};

pub fn parseSessionSearchQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
) !ParsedSessionSearchQuery {
    const trimmed_query = std.mem.trim(u8, query, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, trimmed_query, "re:")) {
        const pattern = std.mem.trim(u8, trimmed_query[3..], &std.ascii.whitespace);
        return .{
            .mode = .regex,
            .tokens = try allocator.alloc(SessionSearchToken, 0),
            .regex_pattern = pattern,
            .regex_valid = pattern.len > 0 and simpleRegexPatternIsValid(pattern),
        };
    }

    var tokens = std.ArrayList(SessionSearchToken).empty;
    errdefer tokens.deinit(allocator);

    var index: usize = 0;
    while (index < trimmed_query.len) {
        while (index < trimmed_query.len and std.ascii.isWhitespace(trimmed_query[index])) : (index += 1) {}
        if (index >= trimmed_query.len) break;

        var field: SessionSearchField = .any;
        if (detectSessionSearchField(trimmed_query[index..])) |match| {
            field = match.field;
            index += match.consumed;
        }

        if (index >= trimmed_query.len) break;

        if (trimmed_query[index] == '"') {
            index += 1;
            const start = index;
            while (index < trimmed_query.len and trimmed_query[index] != '"') : (index += 1) {}
            const value = std.mem.trim(u8, trimmed_query[start..@min(index, trimmed_query.len)], &std.ascii.whitespace);
            if (value.len > 0) {
                try tokens.append(allocator, .{
                    .field = field,
                    .kind = .phrase,
                    .value = value,
                });
            }
            if (index < trimmed_query.len and trimmed_query[index] == '"') index += 1;
            continue;
        }

        const start = index;
        while (index < trimmed_query.len and !std.ascii.isWhitespace(trimmed_query[index])) : (index += 1) {}
        const value = std.mem.trim(u8, trimmed_query[start..index], &std.ascii.whitespace);
        if (value.len == 0) continue;

        try tokens.append(allocator, .{
            .field = field,
            .kind = .fuzzy,
            .value = value,
        });
    }

    return .{
        .mode = .tokens,
        .tokens = try tokens.toOwnedSlice(allocator),
    };
}

pub fn filterAndSortSessions(
    allocator: std.mem.Allocator,
    sessions: []const SessionSearchInfo,
    query: []const u8,
    options: SessionSearchOptions,
) ![]SessionSearchMatch {
    const trimmed_query = std.mem.trim(u8, query, &std.ascii.whitespace);
    var parsed = try parseSessionSearchQuery(allocator, trimmed_query);
    defer parsed.deinit(allocator);

    var matches = std.ArrayList(SessionSearchMatch).empty;
    errdefer matches.deinit(allocator);

    for (sessions, 0..) |session, index| {
        if (!matchesSessionNameFilter(session, options.name_filter)) continue;
        if (trimmed_query.len == 0) {
            try matches.append(allocator, .{
                .session_index = index,
                .score = 0,
            });
            continue;
        }

        const result = matchSessionSearchQuery(session, parsed);
        if (!result.matches) continue;

        try matches.append(allocator, .{
            .session_index = index,
            .score = result.score,
        });
    }

    if (trimmed_query.len > 0 and options.sort_mode == .relevance) {
        std.mem.sort(SessionSearchMatch, matches.items, sessions, struct {
            fn lessThan(all_sessions: []const SessionSearchInfo, lhs: SessionSearchMatch, rhs: SessionSearchMatch) bool {
                if (lhs.score != rhs.score) return lhs.score < rhs.score;

                const lhs_session = all_sessions[lhs.session_index];
                const rhs_session = all_sessions[rhs.session_index];
                const modified_order = std.mem.order(u8, lhs_session.modified_timestamp, rhs_session.modified_timestamp);
                if (modified_order != .eq) return modified_order == .gt;
                return std.mem.order(u8, lhs_session.path, rhs_session.path) == .lt;
            }
        }.lessThan);
    }

    return try matches.toOwnedSlice(allocator);
}

fn detectSessionSearchField(query: []const u8) ?struct {
    field: SessionSearchField,
    consumed: usize,
} {
    const prefix_matches = [_]struct {
        prefix: []const u8,
        field: SessionSearchField,
    }{
        .{ .prefix = "name:", .field = .name },
        .{ .prefix = "content:", .field = .content },
        .{ .prefix = "cwd:", .field = .cwd },
        .{ .prefix = "id:", .field = .id },
    };

    inline for (prefix_matches) |candidate| {
        if (std.mem.startsWith(u8, query, candidate.prefix)) {
            return .{
                .field = candidate.field,
                .consumed = candidate.prefix.len,
            };
        }
    }

    return null;
}

fn matchesSessionNameFilter(session: SessionSearchInfo, filter: SessionSearchNameFilter) bool {
    return switch (filter) {
        .all => true,
        .named => if (session.name) |name|
            std.mem.trim(u8, name, &std.ascii.whitespace).len > 0
        else
            false,
    };
}

const SessionSearchMatchResult = struct {
    matches: bool,
    score: i32,
};

fn matchSessionSearchQuery(
    session: SessionSearchInfo,
    query: ParsedSessionSearchQuery,
) SessionSearchMatchResult {
    if (query.mode == .regex) {
        if (!query.regex_valid) return .{ .matches = false, .score = 0 };
        const match_index = simpleRegexIndexOfCaseInsensitive(session.search_text, query.regex_pattern) orelse return .{
            .matches = false,
            .score = 0,
        };
        return .{ .matches = true, .score = @intCast(match_index) };
    }

    if (query.tokens.len == 0) return .{ .matches = true, .score = 0 };

    var total_score: i32 = 0;
    for (query.tokens) |token| {
        const text = switch (token.field) {
            .any => session.search_text,
            .name => session.name orelse "",
            .content => session.all_messages_text,
            .cwd => session.cwd,
            .id => session.id,
        };

        switch (token.kind) {
            .phrase => {
                const match_index = (normalizedPhraseIndex(std.heap.page_allocator, text, token.value) catch null) orelse return .{
                    .matches = false,
                    .score = 0,
                };
                total_score += @as(i32, @intCast(match_index * 10));
            },
            .fuzzy => {
                const match = fuzzy.fuzzyMatchRanked(token.value, text);
                if (!match.matches) {
                    return .{
                        .matches = false,
                        .score = 0,
                    };
                }
                total_score += match.score;
            },
        }
    }

    return .{
        .matches = true,
        .score = total_score,
    };
}

fn normalizedPhraseIndex(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8) !?usize {
    const normalized_haystack = try normalizeWhitespaceLowerAlloc(allocator, haystack);
    defer allocator.free(normalized_haystack);
    const normalized_needle = try normalizeWhitespaceLowerAlloc(allocator, needle);
    defer allocator.free(normalized_needle);
    return std.mem.indexOf(u8, normalized_haystack, normalized_needle);
}

fn normalizeWhitespaceLowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var pending_space = false;
    var wrote_any = false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (wrote_any) pending_space = true;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        try out.append(allocator, std.ascii.toLower(byte));
        wrote_any = true;
    }
    return try out.toOwnedSlice(allocator);
}

fn simpleRegexPatternIsValid(pattern: []const u8) bool {
    var escaped = false;
    var paren_depth: usize = 0;
    for (pattern) |byte| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '(') {
            paren_depth += 1;
        } else if (byte == ')') {
            if (paren_depth == 0) return false;
            paren_depth -= 1;
        } else if (byte == '[') {
            return false;
        }
    }
    return !escaped and paren_depth == 0;
}

fn simpleRegexIndexOfCaseInsensitive(haystack: []const u8, pattern: []const u8) ?usize {
    if (!simpleRegexPatternIsValid(pattern)) return null;
    var start: usize = 0;
    while (start <= haystack.len) : (start += 1) {
        if (simpleRegexMatchesAt(haystack, start, pattern)) return start;
        if (start == haystack.len) break;
    }
    return null;
}

fn simpleRegexMatchesAt(haystack: []const u8, start: usize, pattern: []const u8) bool {
    var hay_index = start;
    var pat_index: usize = 0;
    while (pat_index < pattern.len) {
        if (pat_index + 1 < pattern.len and pattern[pat_index] == '\\' and pattern[pat_index + 1] == 'b') {
            if (!isWordBoundary(haystack, hay_index)) return false;
            pat_index += 2;
            continue;
        }
        if (pattern[pat_index] == '\\' and pat_index + 1 < pattern.len) {
            pat_index += 1;
        }
        if (hay_index >= haystack.len) return false;
        const pattern_byte = pattern[pat_index];
        if (pattern_byte != '.' and std.ascii.toLower(haystack[hay_index]) != std.ascii.toLower(pattern_byte)) return false;
        hay_index += 1;
        pat_index += 1;
    }
    return true;
}

fn isWordBoundary(text: []const u8, index: usize) bool {
    const before_word = index > 0 and isRegexWordByte(text[index - 1]);
    const after_word = index < text.len and isRegexWordByte(text[index]);
    return before_word != after_word;
}

fn isRegexWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn testSession(
    id: []const u8,
    path: []const u8,
    name: ?[]const u8,
    cwd: []const u8,
    modified_timestamp: []const u8,
    all_messages_text: []const u8,
    search_text: []const u8,
) SessionSearchInfo {
    return .{
        .path = path,
        .id = id,
        .cwd = cwd,
        .name = name,
        .created_timestamp = "2026-01-01T00:00:00.000Z",
        .modified_timestamp = modified_timestamp,
        .message_count = 1,
        .first_message = all_messages_text,
        .all_messages_text = all_messages_text,
        .search_text = search_text,
    };
}

test "session search query parser supports field prefixes and phrases" {
    var parsed = try parseSessionSearchQuery(
        std.testing.allocator,
        "name:\"Night Shift\" content:panic cwd:/tmp/project id:session-1",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try std.testing.expectEqual(SessionSearchField.name, parsed.tokens[0].field);
    try std.testing.expectEqual(SessionSearchTokenKind.phrase, parsed.tokens[0].kind);
    try std.testing.expectEqualStrings("Night Shift", parsed.tokens[0].value);
    try std.testing.expectEqual(SessionSearchField.content, parsed.tokens[1].field);
    try std.testing.expectEqualStrings("panic", parsed.tokens[1].value);
    try std.testing.expectEqual(SessionSearchField.cwd, parsed.tokens[2].field);
    try std.testing.expectEqualStrings("/tmp/project", parsed.tokens[2].value);
    try std.testing.expectEqual(SessionSearchField.id, parsed.tokens[3].field);
    try std.testing.expectEqualStrings("session-1", parsed.tokens[3].value);
}

test "session search filters invalid regex and matches valid regex case-insensitively" {
    const sessions = [_]SessionSearchInfo{
        testSession("one", "/tmp/one.jsonl", null, "/repo/one", "2026-01-01T00:00:01.000Z", "Auth Panic", "one Auth Panic /repo/one"),
        testSession("two", "/tmp/two.jsonl", null, "/repo/two", "2026-01-01T00:00:02.000Z", "ordinary output", "two ordinary output /repo/two"),
    };

    const valid = try filterAndSortSessions(std.testing.allocator, &sessions, "re:\\bpanic", .{});
    defer std.testing.allocator.free(valid);
    try std.testing.expectEqual(@as(usize, 1), valid.len);
    try std.testing.expectEqual(@as(usize, 0), valid[0].session_index);

    const invalid = try filterAndSortSessions(std.testing.allocator, &sessions, "re:[panic", .{});
    defer std.testing.allocator.free(invalid);
    try std.testing.expectEqual(@as(usize, 0), invalid.len);
}

test "session search normalizes phrase whitespace and applies named filter" {
    const sessions = [_]SessionSearchInfo{
        testSession("named", "/tmp/named.jsonl", "Release Notes", "/repo/named", "2026-01-01T00:00:01.000Z", "alpha\n\n  beta", "named Release Notes alpha\n\n  beta /repo/named"),
        testSession("blank", "/tmp/blank.jsonl", "  ", "/repo/blank", "2026-01-01T00:00:02.000Z", "alpha beta", "blank alpha beta /repo/blank"),
        testSession("unnamed", "/tmp/unnamed.jsonl", null, "/repo/unnamed", "2026-01-01T00:00:03.000Z", "alpha beta", "unnamed alpha beta /repo/unnamed"),
    };

    const matches = try filterAndSortSessions(
        std.testing.allocator,
        &sessions,
        "content:\"alpha beta\"",
        .{ .name_filter = .named },
    );
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].session_index);
}

test "session search relevance ties sort by modified timestamp then path" {
    const sessions = [_]SessionSearchInfo{
        testSession("older", "/tmp/c.jsonl", null, "/repo/older", "2026-01-01T00:00:01.000Z", "alpha one", "alpha one"),
        testSession("newer-b", "/tmp/b.jsonl", null, "/repo/newer-b", "2026-01-01T00:00:03.000Z", "alpha two", "alpha two"),
        testSession("newer-a", "/tmp/a.jsonl", null, "/repo/newer-a", "2026-01-01T00:00:03.000Z", "alpha three", "alpha three"),
    };

    const matches = try filterAndSortSessions(std.testing.allocator, &sessions, "\"alpha\"", .{});
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(@as(usize, 2), matches[0].session_index);
    try std.testing.expectEqual(@as(usize, 1), matches[1].session_index);
    try std.testing.expectEqual(@as(usize, 0), matches[2].session_index);
}
