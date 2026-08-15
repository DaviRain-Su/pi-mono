const std = @import("std");
const select_list = @import("vaxis-widgets").components.select_list;
const fuzzy = @import("shared").fuzzy;

pub const Item = select_list.SelectItem;

pub const Match = fuzzy.RankedFuzzyMatch;

const RankedItem = struct {
    item: Item,
    score: i32,
    original_index: usize,
};

pub const fuzzyMatch = fuzzy.fuzzyMatchRanked;

pub fn fuzzyFilterAlloc(
    allocator: std.mem.Allocator,
    items: []const Item,
    query: []const u8,
) std.mem.Allocator.Error![]Item {
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) {
        return allocator.dupe(Item, items);
    }

    var ranked = std.ArrayList(RankedItem).empty;
    defer ranked.deinit(allocator);

    for (items, 0..) |item, index| {
        var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
        var total_score: i32 = 0;
        var all_match = true;

        while (tokens.next()) |token| {
            const match = fuzzyMatch(token, item.display());
            if (!match.matches) {
                all_match = false;
                break;
            }
            total_score += match.score;
        }

        if (!all_match) continue;

        try ranked.append(allocator, .{
            .item = item,
            .score = total_score,
            .original_index = index,
        });
    }

    std.mem.sort(RankedItem, ranked.items, {}, lessThanRankedItem);

    const filtered = try allocator.alloc(Item, ranked.items.len);
    for (ranked.items, 0..) |entry, index| {
        filtered[index] = entry.item;
    }
    return filtered;
}

fn lessThanRankedItem(_: void, lhs: RankedItem, rhs: RankedItem) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    return lhs.original_index < rhs.original_index;
}

test "fuzzy match rewards boundaries and consecutive matches" {
    const boundary = fuzzyMatch("rd", "README.md");
    const interior = fuzzyMatch("rd", "board");

    try std.testing.expect(boundary.matches);
    try std.testing.expect(interior.matches);
    try std.testing.expect(boundary.score < interior.score);
}

test "fuzzy filter sorts best matches first" {
    const allocator = std.testing.allocator;

    const items = [_]Item{
        .{ .value = "reload", .label = "reload" },
        .{ .value = "read", .label = "read" },
        .{ .value = "render", .label = "render" },
    };

    const filtered = try fuzzyFilterAlloc(allocator, &items, "rd");
    defer allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 3), filtered.len);
    try std.testing.expectEqualStrings("read", filtered[0].value);
}
