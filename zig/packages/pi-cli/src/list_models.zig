const std = @import("std");
const ai = @import("ai");
const fuzzy = @import("shared").fuzzy;

const ModelRow = struct {
    provider: []const u8,
    model: []const u8,
    context: []u8,
    max_out: []u8,
    thinking: []const u8,
    images: []const u8,

    fn deinit(self: *ModelRow, allocator: std.mem.Allocator) void {
        allocator.free(self.context);
        allocator.free(self.max_out);
        self.* = undefined;
    }
};

pub fn formatTokenCount(allocator: std.mem.Allocator, count: u32) ![]u8 {
    if (count >= 1_000_000) {
        const whole = count / 1_000_000;
        const decimal = (count % 1_000_000) / 100_000;
        if (decimal == 0) return std.fmt.allocPrint(allocator, "{d}M", .{whole});
        return std.fmt.allocPrint(allocator, "{d}.{d}M", .{ whole, decimal });
    }
    if (count >= 1_000) {
        const whole = count / 1_000;
        const decimal = (count % 1_000) / 100;
        if (decimal == 0) return std.fmt.allocPrint(allocator, "{d}K", .{whole});
        return std.fmt.allocPrint(allocator, "{d}.{d}K", .{ whole, decimal });
    }
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

pub fn listModels(
    allocator: std.mem.Allocator,
    search_pattern: ?[]const u8,
    stdout: *std.Io.Writer,
) !void {
    const summaries = try ai.model_registry.listSummaries(allocator);
    defer allocator.free(summaries);

    if (summaries.len == 0) {
        try stdout.writeAll("No models available. Check your installation or add models to models.json.\n");
        return;
    }

    var rows = std.ArrayList(ModelRow).empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    for (summaries) |summary| {
        if (search_pattern) |pattern| {
            const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ summary.provider, summary.id });
            defer allocator.free(label);
            if (!fuzzy.fuzzyMatchRanked(pattern, label).matches) continue;
        }

        try rows.append(allocator, .{
            .provider = summary.provider,
            .model = summary.id,
            .context = try formatTokenCount(allocator, summary.context_window),
            .max_out = try formatTokenCount(allocator, summary.max_tokens),
            .thinking = if (summary.reasoning) "yes" else "no",
            .images = if (hasInputType(summary.input_types, "image")) "yes" else "no",
        });
    }

    if (rows.items.len == 0) {
        try stdout.print("No models matching \"{s}\"\n", .{search_pattern.?});
        return;
    }

    std.mem.sort(ModelRow, rows.items, {}, struct {
        fn lessThan(_: void, lhs: ModelRow, rhs: ModelRow) bool {
            const provider_order = std.mem.order(u8, lhs.provider, rhs.provider);
            if (provider_order != .eq) return provider_order == .lt;
            return std.mem.order(u8, lhs.model, rhs.model) == .lt;
        }
    }.lessThan);

    const headers = .{
        .provider = "provider",
        .model = "model",
        .context = "context",
        .max_out = "max-out",
        .thinking = "thinking",
        .images = "images",
    };
    var widths = .{
        .provider = headers.provider.len,
        .model = headers.model.len,
        .context = headers.context.len,
        .max_out = headers.max_out.len,
        .thinking = headers.thinking.len,
        .images = headers.images.len,
    };
    for (rows.items) |row| {
        widths.provider = @max(widths.provider, row.provider.len);
        widths.model = @max(widths.model, row.model.len);
        widths.context = @max(widths.context, row.context.len);
        widths.max_out = @max(widths.max_out, row.max_out.len);
        widths.thinking = @max(widths.thinking, row.thinking.len);
        widths.images = @max(widths.images, row.images.len);
    }

    try printRow(stdout, headers.provider, headers.model, headers.context, headers.max_out, headers.thinking, headers.images, widths);
    for (rows.items) |row| {
        try printRow(stdout, row.provider, row.model, row.context, row.max_out, row.thinking, row.images, widths);
    }
}

fn printRow(
    stdout: *std.Io.Writer,
    provider: []const u8,
    model: []const u8,
    context: []const u8,
    max_out: []const u8,
    thinking: []const u8,
    images: []const u8,
    widths: anytype,
) !void {
    try stdout.print("{s}", .{provider});
    try writePadding(stdout, widths.provider - provider.len + 2);
    try stdout.print("{s}", .{model});
    try writePadding(stdout, widths.model - model.len + 2);
    try stdout.print("{s}", .{context});
    try writePadding(stdout, widths.context - context.len + 2);
    try stdout.print("{s}", .{max_out});
    try writePadding(stdout, widths.max_out - max_out.len + 2);
    try stdout.print("{s}", .{thinking});
    try writePadding(stdout, widths.thinking - thinking.len + 2);
    try stdout.print("{s}\n", .{images});
}

fn writePadding(stdout: *std.Io.Writer, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try stdout.writeByte(' ');
}

fn hasInputType(input_types: []const []const u8, needle: []const u8) bool {
    for (input_types) |input_type| {
        if (std.mem.eql(u8, input_type, needle)) return true;
    }
    return false;
}

test "formatTokenCount compacts thousands and millions" {
    const allocator = std.testing.allocator;
    const small = try formatTokenCount(allocator, 512);
    defer allocator.free(small);
    const thousands = try formatTokenCount(allocator, 1500);
    defer allocator.free(thousands);
    const millions = try formatTokenCount(allocator, 2_000_000);
    defer allocator.free(millions);

    try std.testing.expectEqualStrings("512", small);
    try std.testing.expectEqualStrings("1.5K", thousands);
    try std.testing.expectEqualStrings("2M", millions);
}
