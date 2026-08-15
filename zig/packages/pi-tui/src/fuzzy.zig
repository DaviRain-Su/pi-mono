const shared_fuzzy = @import("shared").fuzzy;

pub const FuzzyMatch = shared_fuzzy.FuzzyMatch;
pub const RankedFuzzyMatch = shared_fuzzy.RankedFuzzyMatch;
pub const FuzzyMatcher = shared_fuzzy.FuzzyMatcher;
pub const fuzzyMatch = shared_fuzzy.fuzzyMatch;
pub const fuzzyMatchRanked = shared_fuzzy.fuzzyMatchRanked;
pub const fuzzyFilterStringItemsAlloc = shared_fuzzy.fuzzyFilterStringItemsAlloc;

test "tui fuzzy module re-exports shared fuzzy helpers" {
    const match = fuzzyMatch("rd", "README.md");
    try @import("std").testing.expect(match.matches);
}
