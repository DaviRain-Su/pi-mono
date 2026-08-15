const std = @import("std");
const tui = @import("tui");
const keybindings_mod = @import("../shared/keybindings.zig");
const render_text = @import("render_text.zig");

pub const ActiveOperationKind = enum {
    agent_wait,
    tool_execution,
    retry,
    compaction,
    bash_execution,
};

pub const ActiveOperationSnapshot = struct {
    kind: ActiveOperationKind,
    label: []u8,
    start_ms: i64,
    delay_ms: u64 = 0,
    attempt: u32 = 0,
    max_attempts: u32 = 0,
};

pub fn formatStatus(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    operation: ?ActiveOperationSnapshot,
    now_ms: i64,
) !?[]u8 {
    const active_operation = operation orelse return null;
    const interrupt_label = try render_text.actionLabel(allocator, keybindings, .interrupt, "Esc");
    defer allocator.free(interrupt_label);
    const elapsed_ms = activeOperationElapsedMs(active_operation.start_ms, now_ms);
    const elapsed_seconds = elapsed_ms / 1000;
    const spinner_frame = activeOperationFrame(active_operation.start_ms, now_ms);

    return switch (active_operation.kind) {
        .agent_wait => try std.fmt.allocPrint(
            allocator,
            "{s} {s} {d}s elapsed ({s} to interrupt)",
            .{ spinner_frame, active_operation.label, elapsed_seconds, interrupt_label },
        ),
        .tool_execution => try std.fmt.allocPrint(
            allocator,
            "{s} Running {s} {d}s elapsed ({s} to interrupt)",
            .{ spinner_frame, active_operation.label, elapsed_seconds, interrupt_label },
        ),
        .bash_execution => try std.fmt.allocPrint(
            allocator,
            "{s} Running bash {d}s elapsed ({s} to interrupt)",
            .{ spinner_frame, elapsed_seconds, interrupt_label },
        ),
        .compaction => try std.fmt.allocPrint(
            allocator,
            "{s} {s} {d}s elapsed ({s} to cancel)",
            .{ spinner_frame, active_operation.label, elapsed_seconds, interrupt_label },
        ),
        .retry => {
            const remaining_ms = active_operation.delay_ms -| elapsed_ms;
            const remaining_seconds = (remaining_ms + 999) / 1000;
            return try std.fmt.allocPrint(
                allocator,
                "{s} Retrying ({d}/{d}) in {d}s... ({s} to cancel)",
                .{ spinner_frame, active_operation.attempt, active_operation.max_attempts, remaining_seconds, interrupt_label },
            );
        },
    };
}

pub fn activeOperationElapsedMs(start_ms: i64, now_ms: i64) u64 {
    if (now_ms <= start_ms) return 0;
    return @intCast(now_ms - start_ms);
}

pub fn activeOperationFrame(start_ms: i64, now_ms: i64) []const u8 {
    const elapsed_ms = activeOperationElapsedMs(start_ms, now_ms);
    const frames = tui.components.loader.DEFAULT_SPINNER_FRAMES[0..];
    if (frames.len == 0) return "";
    const frame_index = @as(usize, @intCast(elapsed_ms / tui.components.loader.DEFAULT_INTERVAL_MS)) % frames.len;
    return frames[frame_index];
}

test "active operation status formats elapsed spinner and interrupt hints" {
    const allocator = std.testing.allocator;
    const label = try allocator.dupe(u8, "Working...");
    defer allocator.free(label);
    const status = (try formatStatus(allocator, null, .{
        .kind = .agent_wait,
        .label = label,
        .start_ms = 1_000,
    }, 1_000)).?;
    defer allocator.free(status);

    try std.testing.expectEqualStrings("⠋ Working... 0s elapsed (Esc to interrupt)", status);
}

test "active operation retry countdown rounds remaining seconds" {
    const allocator = std.testing.allocator;
    const label = try allocator.dupe(u8, "Retrying");
    defer allocator.free(label);
    const status = (try formatStatus(allocator, null, .{
        .kind = .retry,
        .label = label,
        .start_ms = 10_000,
        .delay_ms = 2_500,
        .attempt = 2,
        .max_attempts = 4,
    }, 11_100)).?;
    defer allocator.free(status);

    try std.testing.expect(std.mem.indexOf(u8, status, "Retrying (2/4) in 2s... (Esc to cancel)") != null);
}

test "active operation elapsed clamps before start" {
    try std.testing.expectEqual(@as(u64, 0), activeOperationElapsedMs(2_000, 1_000));
}
