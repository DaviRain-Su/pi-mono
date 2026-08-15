const std = @import("std");
const builtin = @import("builtin");

pub const KeySpec = union(enum) {
    ctrl: u8,
    ctrl_alt: u8,
    alt: u8,
    escape,
    enter,
    shift_enter,
    tab,
    shift_tab,
    alt_enter,
    alt_up,
    alt_down,
    alt_left,
    alt_right,
    ctrl_left,
    ctrl_right,
    ctrl_end,
    ctrl_backspace,
    shift_char: u8,
    shift_ctrl_char: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    backspace,
    delete,
    alt_backspace,
    alt_delete,

    pub fn format(self: KeySpec, allocator: std.mem.Allocator) ![]u8 {
        return self.formatForOs(allocator, builtin.target.os.tag);
    }

    pub fn formatForOs(self: KeySpec, allocator: std.mem.Allocator, os_tag: std.Target.Os.Tag) ![]u8 {
        return switch (self) {
            .ctrl => |value| std.fmt.allocPrint(allocator, "Ctrl+{c}", .{std.ascii.toUpper(value)}),
            .ctrl_alt => |value| std.fmt.allocPrint(allocator, "Ctrl+{s}+{c}", .{ altModifierDisplayName(os_tag), std.ascii.toUpper(value) }),
            .alt => |value| std.fmt.allocPrint(allocator, "{s}+{c}", .{ altModifierDisplayName(os_tag), std.ascii.toUpper(value) }),
            .escape => allocator.dupe(u8, "Esc"),
            .enter => allocator.dupe(u8, "Enter"),
            .shift_enter => allocator.dupe(u8, "Shift+Enter"),
            .tab => allocator.dupe(u8, "Tab"),
            .shift_tab => allocator.dupe(u8, "Shift+Tab"),
            .alt_enter => std.fmt.allocPrint(allocator, "{s}+Enter", .{altModifierDisplayName(os_tag)}),
            .alt_up => std.fmt.allocPrint(allocator, "{s}+Up", .{altModifierDisplayName(os_tag)}),
            .alt_down => std.fmt.allocPrint(allocator, "{s}+Down", .{altModifierDisplayName(os_tag)}),
            .alt_left => std.fmt.allocPrint(allocator, "{s}+Left", .{altModifierDisplayName(os_tag)}),
            .alt_right => std.fmt.allocPrint(allocator, "{s}+Right", .{altModifierDisplayName(os_tag)}),
            .ctrl_left => allocator.dupe(u8, "Ctrl+Left"),
            .ctrl_right => allocator.dupe(u8, "Ctrl+Right"),
            .ctrl_end => allocator.dupe(u8, "Ctrl+End"),
            .ctrl_backspace => allocator.dupe(u8, "Ctrl+Backspace"),
            .shift_char => |letter| std.fmt.allocPrint(allocator, "Shift+{c}", .{std.ascii.toUpper(letter)}),
            .shift_ctrl_char => |letter| std.fmt.allocPrint(allocator, "Shift+Ctrl+{c}", .{std.ascii.toUpper(letter)}),
            .up => allocator.dupe(u8, "Up"),
            .down => allocator.dupe(u8, "Down"),
            .left => allocator.dupe(u8, "Left"),
            .right => allocator.dupe(u8, "Right"),
            .home => allocator.dupe(u8, "Home"),
            .end => allocator.dupe(u8, "End"),
            .page_up => allocator.dupe(u8, "PgUp"),
            .page_down => allocator.dupe(u8, "PgDn"),
            .backspace => allocator.dupe(u8, "Backspace"),
            .delete => allocator.dupe(u8, "Delete"),
            .alt_backspace => std.fmt.allocPrint(allocator, "{s}+Backspace", .{altModifierDisplayName(os_tag)}),
            .alt_delete => std.fmt.allocPrint(allocator, "{s}+Delete", .{altModifierDisplayName(os_tag)}),
        };
    }
};

pub fn altModifierDisplayName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .macos) "Option" else "Alt";
}
pub fn parseKeySpec(raw: []const u8) ?KeySpec {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    var buffer: [64]u8 = undefined;
    if (trimmed.len > buffer.len) return null;
    for (trimmed, 0..) |byte, index| {
        buffer[index] = std.ascii.toLower(byte);
    }
    const normalized = buffer[0..trimmed.len];

    if (std.mem.eql(u8, normalized, "escape") or std.mem.eql(u8, normalized, "esc")) return .escape;
    if (std.mem.eql(u8, normalized, "enter") or std.mem.eql(u8, normalized, "return")) return .enter;
    if (std.mem.eql(u8, normalized, "shift+enter") or std.mem.eql(u8, normalized, "shift+return")) return .shift_enter;
    if (std.mem.eql(u8, normalized, "tab")) return .tab;
    if (std.mem.eql(u8, normalized, "shift+tab")) return .shift_tab;
    if (std.mem.eql(u8, normalized, "alt+enter")) return .alt_enter;
    if (std.mem.eql(u8, normalized, "alt+up")) return .alt_up;
    if (std.mem.eql(u8, normalized, "alt+down")) return .alt_down;
    if (std.mem.eql(u8, normalized, "alt+left")) return .alt_left;
    if (std.mem.eql(u8, normalized, "alt+right")) return .alt_right;
    if (std.mem.eql(u8, normalized, "ctrl+left")) return .ctrl_left;
    if (std.mem.eql(u8, normalized, "ctrl+right")) return .ctrl_right;
    if (std.mem.eql(u8, normalized, "ctrl+end")) return .ctrl_end;
    if (std.mem.eql(u8, normalized, "ctrl+backspace")) return .ctrl_backspace;
    if (std.mem.eql(u8, normalized, "up")) return .up;
    if (std.mem.eql(u8, normalized, "down")) return .down;
    if (std.mem.eql(u8, normalized, "left")) return .left;
    if (std.mem.eql(u8, normalized, "right")) return .right;
    if (std.mem.eql(u8, normalized, "home")) return .home;
    if (std.mem.eql(u8, normalized, "end")) return .end;
    if (std.mem.eql(u8, normalized, "pageup") or std.mem.eql(u8, normalized, "page_up")) return .page_up;
    if (std.mem.eql(u8, normalized, "pagedown") or std.mem.eql(u8, normalized, "page_down")) return .page_down;
    if (std.mem.eql(u8, normalized, "backspace")) return .backspace;
    if (std.mem.eql(u8, normalized, "delete") or std.mem.eql(u8, normalized, "del")) return .delete;
    if (std.mem.eql(u8, normalized, "alt+backspace")) return .alt_backspace;
    if (std.mem.eql(u8, normalized, "alt+delete") or std.mem.eql(u8, normalized, "alt+del")) return .alt_delete;

    // shift+ctrl+<letter>: e.g. "shift+ctrl+p"
    if (std.mem.startsWith(u8, normalized, "shift+ctrl+") and normalized.len == 12) {
        const value = normalized[11];
        if (value >= 'a' and value <= 'z') {
            return .{ .shift_ctrl_char = value };
        }
    }

    if (std.mem.startsWith(u8, normalized, "ctrl+alt+") and normalized.len == 10) {
        const value = normalized[9];
        if ((value >= 'a' and value <= 'z') or value == ']') {
            return .{ .ctrl_alt = value };
        }
    }

    // ctrl+<letter, digit, or TS-supported punctuation>: e.g. "ctrl+c", "ctrl+0", "ctrl+-", "ctrl+]"
    if (std.mem.startsWith(u8, normalized, "ctrl+") and normalized.len == 6) {
        const value = normalized[5];
        if ((value >= 'a' and value <= 'z') or (value >= '0' and value <= '9') or value == '-' or value == ']') {
            return .{ .ctrl = value };
        }
    }

    if (std.mem.startsWith(u8, normalized, "alt+") and normalized.len == 5) {
        const value = normalized[4];
        if (value >= 'a' and value <= 'z') {
            return .{ .alt = value };
        }
    }

    // shift+<letter>: e.g. "shift+l", "shift+t"
    if (std.mem.startsWith(u8, normalized, "shift+") and normalized.len == 7) {
        const value = normalized[6];
        if (value >= 'a' and value <= 'z') {
            return .{ .shift_char = value };
        }
    }

    return null;
}

test "key spec parse handles supported formats" {
    try std.testing.expectEqual(KeySpec.ctrl_left, parseKeySpec("ctrl+left").?);
    try std.testing.expectEqual(KeySpec.ctrl_right, parseKeySpec("ctrl+right").?);
    try std.testing.expectEqual(KeySpec.alt_left, parseKeySpec("alt+left").?);
    try std.testing.expectEqual(KeySpec.alt_right, parseKeySpec("alt+right").?);
    try std.testing.expectEqual(KeySpec.ctrl_backspace, parseKeySpec("ctrl+backspace").?);
    try std.testing.expectEqualDeep(KeySpec{ .shift_char = 'l' }, parseKeySpec("shift+l").?);
    try std.testing.expectEqualDeep(KeySpec{ .shift_ctrl_char = 'p' }, parseKeySpec("shift+ctrl+p").?);
    try std.testing.expectEqual(KeySpec.shift_tab, parseKeySpec("shift+tab").?);
    try std.testing.expectEqual(KeySpec.escape, parseKeySpec("escape").?);
    try std.testing.expectEqualDeep(KeySpec{ .ctrl = 'c' }, parseKeySpec("ctrl+c").?);
}

test "key spec display labels use Option on macOS while matching Alt" {
    const allocator = std.testing.allocator;
    const alt_enter = parseKeySpec("alt+enter").?;
    const mac = try alt_enter.formatForOs(allocator, .macos);
    defer allocator.free(mac);
    const linux = try alt_enter.formatForOs(allocator, .linux);
    defer allocator.free(linux);
    try std.testing.expectEqualStrings("Option+Enter", mac);
    try std.testing.expectEqualStrings("Alt+Enter", linux);
}
