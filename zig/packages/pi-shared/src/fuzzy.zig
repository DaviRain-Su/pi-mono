const std = @import("std");

pub const FuzzyMatch = struct {
    matches: bool,
    score: f64,
};

pub const RankedFuzzyMatch = struct {
    matches: bool,
    score: i32,
};

/// Generic fuzzy matcher parameterised by a `Cfg` namespace.
///
/// Required `Cfg` declarations:
///   - `Score: type`                    Numeric type used for scores (e.g. `f64`, `i32`).
///   - `boundary_bonus: Score`          Subtracted from score on word-boundary match.
///   - `consecutive_penalty_unit: Score`Subtracted per `consecutive_matches` step.
///   - `gap_weight: Score`              Added per byte of gap between matches.
///   - `position_weight: Score`         Multiplied with byte index and added per match.
///   - `exact_match_bonus: Score`       Subtracted on exact case-insensitive equality (0 = disabled).
///   - `swap_bonus: Score`              Added when a swapped alphanumeric retry succeeds.
///   - `trim_query: bool`               If true, trim whitespace from the query before matching.
///   - `boundary_includes_newline: bool`If true, '\n' and '\r' also count as word boundaries.
pub fn FuzzyMatcher(comptime Cfg: type) type {
    return struct {
        pub const Score = Cfg.Score;
        pub const Match = struct {
            matches: bool,
            score: Score,
        };

        /// Match `query` against `text`. Honours `Cfg.trim_query`.
        pub fn match(query: []const u8, text: []const u8) Match {
            const effective = if (comptime Cfg.trim_query)
                std.mem.trim(u8, query, " \t\r\n")
            else
                query;
            return matchNormalized(effective, text);
        }

        /// Match with an automatic retry on a swapped alphanumeric query.
        pub fn matchWithSwap(query: []const u8, text: []const u8) Match {
            if (query.len == 0) return .{ .matches = true, .score = 0 };

            const primary = match(query, text);
            if (primary.matches) return primary;

            var swapped_buffer: [256]u8 = undefined;
            const swapped = buildSwappedQuery(query, swapped_buffer[0..]) orelse return primary;
            const swapped_match = match(swapped, text);
            if (!swapped_match.matches) return primary;

            return .{
                .matches = true,
                .score = swapped_match.score + Cfg.swap_bonus,
            };
        }

        /// Core scoring routine. `query` is assumed already normalized.
        pub fn matchNormalized(query: []const u8, text: []const u8) Match {
            if (query.len == 0) return .{ .matches = true, .score = 0 };
            if (query.len > text.len) return .{ .matches = false, .score = 0 };

            var query_index: usize = 0;
            var score: Score = 0;
            var last_match_index: ?usize = null;
            var consecutive_matches: usize = 0;

            for (text, 0..) |byte, index| {
                if (query_index >= query.len) break;
                if (std.ascii.toLower(byte) != std.ascii.toLower(query[query_index])) continue;

                const is_word_boundary = index == 0 or isWordBoundary(text[index - 1]);
                if (last_match_index) |last| {
                    if (last + 1 == index) {
                        consecutive_matches += 1;
                        score -= fromInt(consecutive_matches) * Cfg.consecutive_penalty_unit;
                    } else {
                        consecutive_matches = 0;
                        score += fromInt(index - last - 1) * Cfg.gap_weight;
                    }
                } else {
                    consecutive_matches = 0;
                }

                if (is_word_boundary) score -= Cfg.boundary_bonus;
                score += fromInt(index) * Cfg.position_weight;

                last_match_index = index;
                query_index += 1;
            }

            if (query_index < query.len) return .{ .matches = false, .score = 0 };

            if (comptime Cfg.exact_match_bonus != 0) {
                if (std.ascii.eqlIgnoreCase(query, text)) score -= Cfg.exact_match_bonus;
            }

            return .{ .matches = true, .score = score };
        }

        /// Build a swapped alphanumeric variant of `query`: either `alpha+digit`
        /// becomes `digit+alpha` or vice versa. Returns `null` if `query` is not
        /// a contiguous alpha-then-digit (or digit-then-alpha) sequence.
        pub fn buildSwappedQuery(query: []const u8, buffer: []u8) ?[]const u8 {
            if (query.len == 0 or query.len > buffer.len) return null;

            // Try alpha-prefix + digit-suffix.
            var split_index: usize = 0;
            while (split_index < query.len and std.ascii.isAlphabetic(query[split_index])) : (split_index += 1) {}
            if (split_index > 0 and split_index < query.len) {
                var digit_index = split_index;
                while (digit_index < query.len and std.ascii.isDigit(query[digit_index])) : (digit_index += 1) {}
                if (digit_index == query.len) {
                    @memcpy(buffer[0 .. query.len - split_index], query[split_index..]);
                    @memcpy(buffer[query.len - split_index .. query.len], query[0..split_index]);
                    return buffer[0..query.len];
                }
            }

            // Try digit-prefix + alpha-suffix.
            split_index = 0;
            while (split_index < query.len and std.ascii.isDigit(query[split_index])) : (split_index += 1) {}
            if (split_index > 0 and split_index < query.len) {
                var alpha_index = split_index;
                while (alpha_index < query.len and std.ascii.isAlphabetic(query[alpha_index])) : (alpha_index += 1) {}
                if (alpha_index == query.len) {
                    @memcpy(buffer[0 .. query.len - split_index], query[split_index..]);
                    @memcpy(buffer[query.len - split_index .. query.len], query[0..split_index]);
                    return buffer[0..query.len];
                }
            }

            return null;
        }

        fn isWordBoundary(byte: u8) bool {
            if (comptime Cfg.boundary_includes_newline) {
                return switch (byte) {
                    ' ', '\t', '\n', '\r', '-', '_', '.', '/', ':' => true,
                    else => false,
                };
            }
            return switch (byte) {
                ' ', '\t', '-', '_', '.', '/', ':' => true,
                else => false,
            };
        }

        fn fromInt(x: usize) Score {
            return switch (@typeInfo(Score)) {
                .float => @as(Score, @floatFromInt(x)),
                .int => @as(Score, @intCast(x)),
                else => @compileError("FuzzyMatcher: Cfg.Score must be an int or float type"),
            };
        }
    };
}

/// Cfg used by the string-oriented helpers in this file. Mirrors the prior
/// `matchQuery` behaviour exactly: f64 scores, trims whitespace, treats '\n'/'\r'
/// as boundaries, rewards exact case-insensitive equality.
const StringFuzzyCfg = struct {
    pub const Score = f64;
    pub const boundary_bonus: Score = 10;
    pub const consecutive_penalty_unit: Score = 5;
    pub const gap_weight: Score = 2;
    pub const position_weight: Score = 0.1;
    pub const exact_match_bonus: Score = 100;
    pub const swap_bonus: Score = 5;
    pub const trim_query: bool = true;
    pub const boundary_includes_newline: bool = true;
};

/// Cfg used by model/session ranking and TUI autocomplete. It matches the
/// original autocomplete scoring: i32 scores, no query trim, no newline
/// boundaries, and no exact-match bonus.
const RankedFuzzyCfg = struct {
    pub const Score = i32;
    pub const boundary_bonus: Score = 100;
    pub const consecutive_penalty_unit: Score = 50;
    pub const gap_weight: Score = 20;
    pub const position_weight: Score = 1;
    pub const exact_match_bonus: Score = 0;
    pub const swap_bonus: Score = 50;
    pub const trim_query: bool = false;
    pub const boundary_includes_newline: bool = false;
};

const StringMatcher = FuzzyMatcher(StringFuzzyCfg);
const RankedMatcher = FuzzyMatcher(RankedFuzzyCfg);

pub fn fuzzyMatch(query: []const u8, text: []const u8) FuzzyMatch {
    const result = StringMatcher.matchWithSwap(query, text);
    return .{ .matches = result.matches, .score = result.score };
}

pub fn fuzzyMatchRanked(query: []const u8, text: []const u8) RankedFuzzyMatch {
    const result = RankedMatcher.matchWithSwap(query, text);
    return .{ .matches = result.matches, .score = result.score };
}

pub fn fuzzyFilterStringItemsAlloc(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    query: []const u8,
) ![]const []const u8 {
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) return allocator.dupe([]const u8, items);

    const Ranked = struct {
        item: []const u8,
        score: f64,
        index: usize,
    };

    var ranked = std.ArrayList(Ranked).empty;
    defer ranked.deinit(allocator);

    for (items, 0..) |item, index| {
        var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
        var total_score: f64 = 0;
        var all_match = true;

        while (tokens.next()) |token| {
            const match = fuzzyMatch(token, item);
            if (!match.matches) {
                all_match = false;
                break;
            }
            total_score += match.score;
        }

        if (all_match) {
            try ranked.append(allocator, .{
                .item = item,
                .score = total_score,
                .index = index,
            });
        }
    }

    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn lessThan(_: void, lhs: Ranked, rhs: Ranked) bool {
            if (lhs.score != rhs.score) return lhs.score < rhs.score;
            return lhs.index < rhs.index;
        }
    }.lessThan);

    const out = try allocator.alloc([]const u8, ranked.items.len);
    for (ranked.items, 0..) |entry, index| out[index] = entry.item;
    return out;
}

test "fuzzyMatch rewards exact and boundary matches" {
    const exact = fuzzyMatch("readme", "README");
    const boundary = fuzzyMatch("rd", "README.md");
    const interior = fuzzyMatch("rd", "board");

    try std.testing.expect(exact.matches);
    try std.testing.expect(boundary.matches);
    try std.testing.expect(interior.matches);
    try std.testing.expect(exact.score < boundary.score);
    try std.testing.expect(boundary.score < interior.score);
}

test "fuzzyMatchRanked rewards boundaries and consecutive matches" {
    const boundary = fuzzyMatchRanked("rd", "README.md");
    const interior = fuzzyMatchRanked("rd", "board");

    try std.testing.expect(boundary.matches);
    try std.testing.expect(interior.matches);
    try std.testing.expect(boundary.score < interior.score);
}

test "fuzzyFilterStringItemsAlloc sorts best matches first" {
    const items = [_][]const u8{ "board", "README.md", "src/main.zig" };
    const filtered = try fuzzyFilterStringItemsAlloc(std.testing.allocator, &items, "rd");
    defer std.testing.allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings("README.md", filtered[0]);
}
