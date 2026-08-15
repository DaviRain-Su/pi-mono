pub const BranchSummaryEntry = struct {
    role: []const u8,
    content: []const u8,
};

pub fn collectEntriesForBranchSummary(entries: []const BranchSummaryEntry) []const BranchSummaryEntry {
    return entries;
}
