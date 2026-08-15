const std = @import("std");

const widget_keys = @import("vaxis-widgets").keys;

pub const KeyId = []const u8;
pub const PrintableKey = widget_keys.PrintableKey;
pub const Key = widget_keys.Key;
pub const KeyModifiers = widget_keys.KeyModifiers;
pub const KeyEventType = widget_keys.KeyEventType;
pub const ProtocolEvent = widget_keys.ProtocolEvent;
pub const MouseWheelDirection = widget_keys.MouseWheelDirection;
pub const MouseWheelInput = widget_keys.MouseWheelInput;
pub const MouseClickInput = widget_keys.MouseClickInput;
pub const MouseDragInput = widget_keys.MouseDragInput;
pub const MouseReleaseInput = widget_keys.MouseReleaseInput;
pub const InputEvent = widget_keys.InputEvent;
pub const ParsedInput = widget_keys.ParsedInput;
pub const parsedPasteInput = widget_keys.parsedPasteInput;
pub const parsedMouseWheelInput = widget_keys.parsedMouseWheelInput;
pub const parsedMouseClickInput = widget_keys.parsedMouseClickInput;
pub const parsedMouseDragInput = widget_keys.parsedMouseDragInput;
pub const parsedMouseReleaseInput = widget_keys.parsedMouseReleaseInput;
pub const parsedInputFromVaxisKey = widget_keys.parsedInputFromVaxisKey;

pub const MODIFIERS = struct {
    pub const shift: u8 = 1;
    pub const alt: u8 = 2;
    pub const ctrl: u8 = 4;
    pub const super: u8 = 8;
};

const LOCK_MASK: u8 = 64 + 128;
const ESC = "\x1b";

var kitty_protocol_active = false;
var last_event_type: KeyEventType = .press;

pub fn setKittyProtocolActive(active: bool) void {
    kitty_protocol_active = active;
}

pub fn isKittyProtocolActive() bool {
    return kitty_protocol_active;
}

pub fn isKeyRelease(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\x1b[200~") != null) return false;
    return containsAny(data, &.{ ":3u", ":3~", ":3A", ":3B", ":3C", ":3D", ":3H", ":3F" });
}

pub fn isKeyRepeat(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\x1b[200~") != null) return false;
    return containsAny(data, &.{ ":2u", ":2~", ":2A", ":2B", ":2C", ":2D", ":2H", ":2F" });
}

pub fn lastEventType() KeyEventType {
    return last_event_type;
}

pub fn matchesKey(data: []const u8, key_id: KeyId) bool {
    const parsed = parseKeyId(key_id) orelse return false;
    const modifier = parsed.modifier();
    const key = parsed.key;

    if (eqlKey(key, "escape") or eqlKey(key, "esc")) {
        return modifier == 0 and (std.mem.eql(u8, data, ESC) or matchesKittySequence(data, 27, 0) or matchesModifyOtherKeys(data, 27, 0));
    }
    if (eqlKey(key, "space")) {
        if (!kitty_protocol_active and modifier == MODIFIERS.ctrl and std.mem.eql(u8, data, "\x00")) return true;
        if (!kitty_protocol_active and modifier == MODIFIERS.alt and std.mem.eql(u8, data, "\x1b ")) return true;
        return if (modifier == 0)
            std.mem.eql(u8, data, " ") or matchesKittySequence(data, 32, 0) or matchesModifyOtherKeys(data, 32, 0)
        else
            matchesKittySequence(data, 32, modifier) or matchesModifyOtherKeys(data, 32, modifier);
    }
    if (eqlKey(key, "tab")) {
        if (modifier == MODIFIERS.shift) return std.mem.eql(u8, data, "\x1b[Z") or matchesKittySequence(data, 9, modifier) or matchesModifyOtherKeys(data, 9, modifier);
        if (modifier == 0) return std.mem.eql(u8, data, "\t") or matchesKittySequence(data, 9, 0);
        return matchesKittySequence(data, 9, modifier) or matchesModifyOtherKeys(data, 9, modifier);
    }
    if (eqlKey(key, "enter") or eqlKey(key, "return")) {
        if (modifier == MODIFIERS.shift) {
            if (matchesKittySequence(data, 13, modifier) or matchesKittySequence(data, 57414, modifier) or matchesModifyOtherKeys(data, 13, modifier)) return true;
            return kitty_protocol_active and (std.mem.eql(u8, data, "\x1b\r") or std.mem.eql(u8, data, "\n"));
        }
        if (modifier == MODIFIERS.alt) {
            if (matchesKittySequence(data, 13, modifier) or matchesKittySequence(data, 57414, modifier) or matchesModifyOtherKeys(data, 13, modifier)) return true;
            return !kitty_protocol_active and std.mem.eql(u8, data, "\x1b\r");
        }
        if (modifier == 0) return std.mem.eql(u8, data, "\r") or (!kitty_protocol_active and std.mem.eql(u8, data, "\n")) or std.mem.eql(u8, data, "\x1bOM") or matchesKittySequence(data, 13, 0) or matchesKittySequence(data, 57414, 0);
        return matchesKittySequence(data, 13, modifier) or matchesKittySequence(data, 57414, modifier) or matchesModifyOtherKeys(data, 13, modifier);
    }
    if (eqlKey(key, "backspace")) {
        if (modifier == MODIFIERS.alt) return std.mem.eql(u8, data, "\x1b\x7f") or std.mem.eql(u8, data, "\x1b\x08") or matchesKittySequence(data, 127, modifier) or matchesModifyOtherKeys(data, 127, modifier);
        if (modifier == 0) return std.mem.eql(u8, data, "\x7f") or std.mem.eql(u8, data, "\x08") or matchesKittySequence(data, 127, 0) or matchesModifyOtherKeys(data, 127, 0);
        return matchesKittySequence(data, 127, modifier) or matchesModifyOtherKeys(data, 127, modifier);
    }

    if (functionalCodepoint(key)) |codepoint| {
        if (modifier == 0 and matchesLegacyKey(data, key)) return true;
        if (modifier == MODIFIERS.shift and matchesLegacyShift(data, key)) return true;
        if (modifier == MODIFIERS.ctrl and matchesLegacyCtrl(data, key)) return true;
        return matchesKittySequence(data, codepoint, modifier);
    }

    if (arrowCodepoint(key)) |codepoint| {
        if (modifier == MODIFIERS.alt) {
            if ((eqlKey(key, "left") and (std.mem.eql(u8, data, "\x1b[1;3D") or (!kitty_protocol_active and std.mem.eql(u8, data, "\x1bB")) or std.mem.eql(u8, data, "\x1bb"))) or
                (eqlKey(key, "right") and (std.mem.eql(u8, data, "\x1b[1;3C") or (!kitty_protocol_active and std.mem.eql(u8, data, "\x1bF")) or std.mem.eql(u8, data, "\x1bf"))) or
                (eqlKey(key, "up") and std.mem.eql(u8, data, "\x1bp")) or
                (eqlKey(key, "down") and std.mem.eql(u8, data, "\x1bn")))
            {
                return true;
            }
        }
        if (modifier == 0 and matchesLegacyKey(data, key)) return true;
        if (modifier == MODIFIERS.shift and matchesLegacyShift(data, key)) return true;
        if (modifier == MODIFIERS.ctrl and matchesLegacyCtrl(data, key)) return true;
        return matchesKittySequence(data, codepoint, modifier);
    }

    if (functionKeyIndex(key)) |index| {
        return modifier == 0 and matchesLegacyFunction(data, index);
    }

    if (key.len == 1 and isPrintableKey(key[0])) {
        const codepoint: i32 = std.ascii.toLower(key[0]);
        const raw_ctrl = rawCtrlChar(key[0]);
        const is_letter = codepoint >= 'a' and codepoint <= 'z';
        const is_digit = codepoint >= '0' and codepoint <= '9';

        if (modifier == MODIFIERS.ctrl + MODIFIERS.alt and !kitty_protocol_active) {
            if (raw_ctrl) |ctrl| {
                if (data.len == 2 and data[0] == 0x1b and data[1] == ctrl) return true;
            }
        }
        if (modifier == MODIFIERS.alt and !kitty_protocol_active and (is_letter or is_digit)) {
            if (data.len == 2 and data[0] == 0x1b and data[1] == key[0]) return true;
        }
        if (modifier == MODIFIERS.ctrl) {
            if (raw_ctrl) |ctrl| {
                if (data.len == 1 and data[0] == ctrl) return true;
            }
            return matchesKittySequence(data, codepoint, modifier) or matchesPrintableModifyOtherKeys(data, codepoint, modifier);
        }
        if (modifier == MODIFIERS.shift and is_letter and data.len == 1 and data[0] == std.ascii.toUpper(key[0])) return true;
        if (modifier != 0) return matchesKittySequence(data, codepoint, modifier) or matchesPrintableModifyOtherKeys(data, codepoint, modifier);
        return (data.len == 1 and data[0] == key[0]) or matchesKittySequence(data, codepoint, 0);
    }

    return false;
}

pub fn parseKeyAlloc(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    if (parseKittySequence(data)) |kitty| return formatParsedKeyAlloc(allocator, kitty.codepoint, kitty.modifier, kitty.base_layout_key);
    if (parseModifyOtherKeysSequence(data)) |other| return formatParsedKeyAlloc(allocator, other.codepoint, other.modifier, null);

    if (kitty_protocol_active and (std.mem.eql(u8, data, "\x1b\r") or std.mem.eql(u8, data, "\n"))) return try allocator.dupe(u8, "shift+enter");
    if (legacySequenceKeyId(data)) |id| return try allocator.dupe(u8, id);

    if (std.mem.eql(u8, data, ESC)) return try allocator.dupe(u8, "escape");
    if (std.mem.eql(u8, data, "\x1c")) return try allocator.dupe(u8, "ctrl+\\");
    if (std.mem.eql(u8, data, "\x1d")) return try allocator.dupe(u8, "ctrl+]");
    if (std.mem.eql(u8, data, "\x1f")) return try allocator.dupe(u8, "ctrl+-");
    if (std.mem.eql(u8, data, "\t")) return try allocator.dupe(u8, "tab");
    if (std.mem.eql(u8, data, "\r") or (!kitty_protocol_active and std.mem.eql(u8, data, "\n")) or std.mem.eql(u8, data, "\x1bOM")) return try allocator.dupe(u8, "enter");
    if (std.mem.eql(u8, data, "\x00")) return try allocator.dupe(u8, "ctrl+space");
    if (std.mem.eql(u8, data, " ")) return try allocator.dupe(u8, "space");
    if (std.mem.eql(u8, data, "\x7f")) return try allocator.dupe(u8, "backspace");
    if (std.mem.eql(u8, data, "\x08")) return try allocator.dupe(u8, "backspace");
    if (std.mem.eql(u8, data, "\x1b[Z")) return try allocator.dupe(u8, "shift+tab");
    if (!kitty_protocol_active and std.mem.eql(u8, data, "\x1b\r")) return try allocator.dupe(u8, "alt+enter");
    if (!kitty_protocol_active and std.mem.eql(u8, data, "\x1b ")) return try allocator.dupe(u8, "alt+space");
    if (std.mem.eql(u8, data, "\x1b\x7f") or std.mem.eql(u8, data, "\x1b\x08")) return try allocator.dupe(u8, "alt+backspace");

    if (!kitty_protocol_active and data.len == 2 and data[0] == 0x1b) {
        const code = data[1];
        if (code >= 1 and code <= 26) return try std.fmt.allocPrint(allocator, "ctrl+alt+{c}", .{code + 96});
        if ((code >= 'a' and code <= 'z') or (code >= '0' and code <= '9')) return try std.fmt.allocPrint(allocator, "alt+{c}", .{code});
    }

    if (data.len == 1) {
        const code = data[0];
        if (code >= 1 and code <= 26) return try std.fmt.allocPrint(allocator, "ctrl+{c}", .{code + 96});
        if (code >= 32 and code <= 126) return try allocator.dupe(u8, data);
    }

    return null;
}

pub fn decodeKittyPrintable(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    const parsed = parseKittySequence(data) orelse return null;
    const modifier = parsed.modifier;
    if ((modifier & ~@as(u8, MODIFIERS.shift | LOCK_MASK)) != 0) return null;
    if ((modifier & (MODIFIERS.alt | MODIFIERS.ctrl)) != 0) return null;
    var codepoint = parsed.codepoint;
    if ((modifier & MODIFIERS.shift) != 0) {
        if (parsed.shifted_key) |shifted| codepoint = shifted;
    }
    codepoint = normalizeKittyFunctionalCodepoint(codepoint);
    if (codepoint < 32) return null;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return null;
    return try allocator.dupe(u8, buf[0..len]);
}

pub fn decodePrintableKey(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    if (try decodeKittyPrintable(allocator, data)) |decoded| return decoded;
    const parsed = parseModifyOtherKeysSequence(data) orelse return null;
    const modifier = parsed.modifier & ~@as(u8, LOCK_MASK);
    if ((modifier & ~@as(u8, MODIFIERS.shift)) != 0 or parsed.codepoint < 32) return null;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(parsed.codepoint), &buf) catch return null;
    return try allocator.dupe(u8, buf[0..len]);
}

const ParsedKeyId = struct {
    key: []const u8,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    fn modifier(self: ParsedKeyId) u8 {
        return (if (self.shift) MODIFIERS.shift else 0) |
            (if (self.alt) MODIFIERS.alt else 0) |
            (if (self.ctrl) MODIFIERS.ctrl else 0) |
            (if (self.super) MODIFIERS.super else 0);
    }
};

const ParsedKittySequence = struct {
    codepoint: i32,
    shifted_key: ?i32 = null,
    base_layout_key: ?i32 = null,
    modifier: u8,
    event_type: KeyEventType,
};

const ParsedModifyOtherKeysSequence = struct {
    codepoint: i32,
    modifier: u8,
};

fn parseKeyId(key_id: []const u8) ?ParsedKeyId {
    if (key_id.len == 0) return null;
    var parsed = ParsedKeyId{ .key = key_id };
    var parts = std.mem.splitScalar(u8, key_id, '+');
    while (parts.next()) |part| {
        if (parts.peek() == null) {
            parsed.key = part;
            break;
        }
        if (eqlKey(part, "ctrl")) parsed.ctrl = true else if (eqlKey(part, "shift")) parsed.shift = true else if (eqlKey(part, "alt")) parsed.alt = true else if (eqlKey(part, "super")) parsed.super = true;
    }
    return if (parsed.key.len == 0) null else parsed;
}

fn parseKittySequence(data: []const u8) ?ParsedKittySequence {
    if (!std.mem.startsWith(u8, data, "\x1b[") or data.len < 4) return null;
    const final = data[data.len - 1];

    if (final == 'u') {
        const payload = data[2 .. data.len - 1];
        var semi = std.mem.splitScalar(u8, payload, ';');
        const code_part = semi.next() orelse return null;
        const mod_part = semi.next();
        if (semi.next() != null) return null;

        var code_iter = std.mem.splitScalar(u8, code_part, ':');
        const codepoint = parseI32(code_iter.next() orelse return null) orelse return null;
        const shifted = parseOptionalI32(code_iter.next());
        const base = parseOptionalI32(code_iter.next());
        if (code_iter.next() != null) return null;

        var modifier: u8 = 0;
        var event_type: KeyEventType = .press;
        if (mod_part) |part| {
            var mod_iter = std.mem.splitScalar(u8, part, ':');
            const raw_modifier = parseI32(mod_iter.next() orelse return null) orelse return null;
            modifier = if (raw_modifier > 0) @intCast(raw_modifier - 1) else 0;
            event_type = parseEventType(mod_iter.next());
        }
        last_event_type = event_type;
        return .{ .codepoint = codepoint, .shifted_key = shifted, .base_layout_key = base, .modifier = modifier, .event_type = event_type };
    }

    if ((final == 'A' or final == 'B' or final == 'C' or final == 'D' or final == 'H' or final == 'F') and std.mem.startsWith(u8, data, "\x1b[1;")) {
        const payload = data[4 .. data.len - 1];
        var mod_iter = std.mem.splitScalar(u8, payload, ':');
        const raw_modifier = parseI32(mod_iter.next() orelse return null) orelse return null;
        const event_type = parseEventType(mod_iter.next());
        last_event_type = event_type;
        const codepoint: i32 = switch (final) {
            'A' => -1,
            'B' => -2,
            'C' => -3,
            'D' => -4,
            'H' => -14,
            'F' => -15,
            else => unreachable,
        };
        return .{ .codepoint = codepoint, .modifier = if (raw_modifier > 0) @intCast(raw_modifier - 1) else 0, .event_type = event_type };
    }

    if (final == '~') {
        const payload = data[2 .. data.len - 1];
        var semi = std.mem.splitScalar(u8, payload, ';');
        const key_num = parseI32(semi.next() orelse return null) orelse return null;
        const mod_part = semi.next();
        var modifier: u8 = 0;
        var event_type: KeyEventType = .press;
        if (mod_part) |part| {
            var mod_iter = std.mem.splitScalar(u8, part, ':');
            const raw_modifier = parseI32(mod_iter.next() orelse return null) orelse return null;
            modifier = if (raw_modifier > 0) @intCast(raw_modifier - 1) else 0;
            event_type = parseEventType(mod_iter.next());
        }
        const codepoint: i32 = switch (key_num) {
            2 => -11,
            3 => -10,
            5 => -12,
            6 => -13,
            7 => -14,
            8 => -15,
            else => return null,
        };
        last_event_type = event_type;
        return .{ .codepoint = codepoint, .modifier = modifier, .event_type = event_type };
    }

    return null;
}

fn parseModifyOtherKeysSequence(data: []const u8) ?ParsedModifyOtherKeysSequence {
    if (!std.mem.startsWith(u8, data, "\x1b[27;") or !std.mem.endsWith(u8, data, "~")) return null;
    const payload = data[5 .. data.len - 1];
    var parts = std.mem.splitScalar(u8, payload, ';');
    const raw_modifier = parseI32(parts.next() orelse return null) orelse return null;
    const codepoint = parseI32(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    return .{ .codepoint = codepoint, .modifier = if (raw_modifier > 0) @intCast(raw_modifier - 1) else 0 };
}

fn matchesKittySequence(data: []const u8, expected_codepoint: i32, expected_modifier: u8) bool {
    const parsed = parseKittySequence(data) orelse return false;
    if ((parsed.modifier & ~@as(u8, LOCK_MASK)) != (expected_modifier & ~@as(u8, LOCK_MASK))) return false;
    const actual = normalizeShiftedLetterIdentityCodepoint(normalizeKittyFunctionalCodepoint(parsed.codepoint), parsed.modifier);
    const expected = normalizeShiftedLetterIdentityCodepoint(normalizeKittyFunctionalCodepoint(expected_codepoint), expected_modifier);
    if (actual == expected) return true;
    if (parsed.base_layout_key) |base| {
        return base == expected_codepoint and !isLatinLetter(actual) and !isKnownSymbol(actual);
    }
    return false;
}

fn matchesModifyOtherKeys(data: []const u8, expected_codepoint: i32, expected_modifier: u8) bool {
    const parsed = parseModifyOtherKeysSequence(data) orelse return false;
    return parsed.codepoint == expected_codepoint and parsed.modifier == expected_modifier;
}

fn matchesPrintableModifyOtherKeys(data: []const u8, expected_codepoint: i32, expected_modifier: u8) bool {
    if (expected_modifier == 0) return false;
    const parsed = parseModifyOtherKeysSequence(data) orelse return false;
    return parsed.modifier == expected_modifier and normalizeShiftedLetterIdentityCodepoint(parsed.codepoint, parsed.modifier) == normalizeShiftedLetterIdentityCodepoint(expected_codepoint, expected_modifier);
}

fn formatParsedKeyAlloc(allocator: std.mem.Allocator, codepoint: i32, modifier: u8, base_layout_key: ?i32) !?[]u8 {
    const normalized = normalizeKittyFunctionalCodepoint(codepoint);
    const identity = normalizeShiftedLetterIdentityCodepoint(normalized, modifier);
    const effective = if (isLatinLetter(identity) or isDigitCodepoint(identity) or isKnownSymbol(identity)) identity else (base_layout_key orelse identity);
    const key_name = keyNameForCodepoint(effective) orelse return null;
    return try formatKeyNameWithModifiersAlloc(allocator, key_name, modifier);
}

fn formatKeyNameWithModifiersAlloc(allocator: std.mem.Allocator, key_name: []const u8, modifier: u8) ![]u8 {
    const effective = modifier & ~@as(u8, LOCK_MASK);
    if ((effective & ~@as(u8, MODIFIERS.shift | MODIFIERS.ctrl | MODIFIERS.alt | MODIFIERS.super)) != 0) return allocator.dupe(u8, key_name);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if ((effective & MODIFIERS.shift) != 0) try out.appendSlice(allocator, "shift+");
    if ((effective & MODIFIERS.ctrl) != 0) try out.appendSlice(allocator, "ctrl+");
    if ((effective & MODIFIERS.alt) != 0) try out.appendSlice(allocator, "alt+");
    if ((effective & MODIFIERS.super) != 0) try out.appendSlice(allocator, "super+");
    try out.appendSlice(allocator, key_name);
    return out.toOwnedSlice(allocator);
}

fn parseEventType(raw: ?[]const u8) KeyEventType {
    const value = parseI32(raw orelse return .press) orelse return .press;
    return switch (value) {
        2 => .repeat,
        3 => .release,
        else => .press,
    };
}

fn parseOptionalI32(raw: ?[]const u8) ?i32 {
    const value = raw orelse return null;
    if (value.len == 0) return null;
    return parseI32(value);
}

fn parseI32(raw: []const u8) ?i32 {
    return std.fmt.parseInt(i32, raw, 10) catch null;
}

fn normalizeKittyFunctionalCodepoint(codepoint: i32) i32 {
    return switch (codepoint) {
        57399 => '0',
        57400 => '1',
        57401 => '2',
        57402 => '3',
        57403 => '4',
        57404 => '5',
        57405 => '6',
        57406 => '7',
        57407 => '8',
        57408 => '9',
        57409 => '.',
        57410 => '/',
        57411 => '*',
        57412 => '-',
        57413 => '+',
        57415 => '=',
        57416 => ',',
        57417 => -4,
        57418 => -3,
        57419 => -1,
        57420 => -2,
        57421 => -12,
        57422 => -13,
        57423 => -14,
        57424 => -15,
        57425 => -11,
        57426 => -10,
        else => codepoint,
    };
}

fn normalizeShiftedLetterIdentityCodepoint(codepoint: i32, modifier: u8) i32 {
    if (((modifier & ~@as(u8, LOCK_MASK)) & MODIFIERS.shift) != 0 and codepoint >= 'A' and codepoint <= 'Z') return codepoint + 32;
    return codepoint;
}

fn rawCtrlChar(key: u8) ?u8 {
    const char = std.ascii.toLower(key);
    if ((char >= 'a' and char <= 'z') or char == '[' or char == '\\' or char == ']' or char == '_') return char & 0x1f;
    if (char == '-') return 31;
    return null;
}

const FUNCTIONAL_CODEPOINTS = std.StaticStringMap(i32).initComptime(.{
    .{ "delete", @as(i32, -10) },
    .{ "insert", @as(i32, -11) },
    .{ "pageup", @as(i32, -12) },
    .{ "pagedown", @as(i32, -13) },
    .{ "home", @as(i32, -14) },
    .{ "end", @as(i32, -15) },
});

const ARROW_CODEPOINTS = std.StaticStringMap(i32).initComptime(.{
    .{ "up", @as(i32, -1) },
    .{ "down", @as(i32, -2) },
    .{ "right", @as(i32, -3) },
    .{ "left", @as(i32, -4) },
});

fn lowercaseLookupI32(map: std.StaticStringMap(i32), key: []const u8) ?i32 {
    var buf: [32]u8 = undefined;
    if (key.len == 0 or key.len > buf.len) return null;
    for (key, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return map.get(buf[0..key.len]);
}

fn functionalCodepoint(key: []const u8) ?i32 {
    return lowercaseLookupI32(FUNCTIONAL_CODEPOINTS, key);
}

fn arrowCodepoint(key: []const u8) ?i32 {
    return lowercaseLookupI32(ARROW_CODEPOINTS, key);
}

fn keyNameForCodepoint(codepoint: i32) ?[]const u8 {
    return switch (codepoint) {
        27 => "escape",
        9 => "tab",
        13, 57414 => "enter",
        32 => "space",
        127 => "backspace",
        -10 => "delete",
        -11 => "insert",
        -12 => "pageUp",
        -13 => "pageDown",
        -14 => "home",
        -15 => "end",
        -1 => "up",
        -2 => "down",
        -3 => "right",
        -4 => "left",
        else => if ((codepoint >= '0' and codepoint <= '9') or (codepoint >= 'a' and codepoint <= 'z') or isKnownSymbol(codepoint)) oneByteKeyName(@intCast(codepoint)) else null,
    };
}

const ONE_BYTE_KEY_NAMES: [128][]const u8 = blk: {
    @setEvalBranchQuota(4096);
    var table: [128][]const u8 = undefined;
    for (&table, 0..) |*slot, byte| {
        const b: u8 = @intCast(byte);
        const is_digit = b >= '0' and b <= '9';
        const is_lower = b >= 'a' and b <= 'z';
        const is_symbol = switch (b) {
            '`', '-', '=', '[', ']', '\\', ';', '\'', ',', '.', '/', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '|', '~', '{', '}', ':', '<', '>', '?' => true,
            else => false,
        };
        slot.* = if (is_digit or is_lower or is_symbol) &[_]u8{b} else "";
    }
    break :blk table;
};

fn oneByteKeyName(byte: u8) []const u8 {
    if (byte >= ONE_BYTE_KEY_NAMES.len) return "";
    return ONE_BYTE_KEY_NAMES[byte];
}

const FUNCTION_KEY_TABLE = [_]struct { name: []const u8, sequences: []const []const u8 }{
    .{ .name = "f1", .sequences = &.{ "\x1bOP", "\x1b[11~", "\x1b[[A" } },
    .{ .name = "f2", .sequences = &.{ "\x1bOQ", "\x1b[12~", "\x1b[[B" } },
    .{ .name = "f3", .sequences = &.{ "\x1bOR", "\x1b[13~", "\x1b[[C" } },
    .{ .name = "f4", .sequences = &.{ "\x1bOS", "\x1b[14~", "\x1b[[D" } },
    .{ .name = "f5", .sequences = &.{ "\x1b[15~", "\x1b[[E" } },
    .{ .name = "f6", .sequences = &.{"\x1b[17~"} },
    .{ .name = "f7", .sequences = &.{"\x1b[18~"} },
    .{ .name = "f8", .sequences = &.{"\x1b[19~"} },
    .{ .name = "f9", .sequences = &.{"\x1b[20~"} },
    .{ .name = "f10", .sequences = &.{"\x1b[21~"} },
    .{ .name = "f11", .sequences = &.{"\x1b[23~"} },
    .{ .name = "f12", .sequences = &.{"\x1b[24~"} },
};

const LEGACY_SEQUENCE_KEY_IDS = blk: {
    const base = [_]struct { []const u8, []const u8 }{
        .{ "\x1bOA", "up" },
        .{ "\x1bOB", "down" },
        .{ "\x1bOC", "right" },
        .{ "\x1bOD", "left" },
        .{ "\x1bOH", "home" },
        .{ "\x1bOF", "end" },
        .{ "\x1b[E", "clear" },
        .{ "\x1bOE", "clear" },
        .{ "\x1bOe", "ctrl+clear" },
        .{ "\x1b[e", "shift+clear" },
        .{ "\x1b[2~", "insert" },
        .{ "\x1b[3~", "delete" },
        .{ "\x1b[5~", "pageUp" },
        .{ "\x1b[[5~", "pageUp" },
        .{ "\x1b[6~", "pageDown" },
        .{ "\x1b[[6~", "pageDown" },
        .{ "\x1bb", "alt+left" },
        .{ "\x1bf", "alt+right" },
        .{ "\x1bp", "alt+up" },
        .{ "\x1bn", "alt+down" },
    };
    var function_count: usize = 0;
    for (FUNCTION_KEY_TABLE) |entry| function_count += entry.sequences.len;
    var entries: [base.len + function_count]struct { []const u8, []const u8 } = undefined;
    for (base, 0..) |entry, i| entries[i] = entry;
    var index: usize = base.len;
    for (FUNCTION_KEY_TABLE) |entry| {
        for (entry.sequences) |seq| {
            entries[index] = .{ seq, entry.name };
            index += 1;
        }
    }
    break :blk std.StaticStringMap([]const u8).initComptime(entries);
};

fn legacySequenceKeyId(data: []const u8) ?[]const u8 {
    return LEGACY_SEQUENCE_KEY_IDS.get(data);
}

fn matchesLegacyKey(data: []const u8, key: []const u8) bool {
    return (eqlKey(key, "up") and (std.mem.eql(u8, data, "\x1b[A") or std.mem.eql(u8, data, "\x1bOA"))) or
        (eqlKey(key, "down") and (std.mem.eql(u8, data, "\x1b[B") or std.mem.eql(u8, data, "\x1bOB"))) or
        (eqlKey(key, "right") and (std.mem.eql(u8, data, "\x1b[C") or std.mem.eql(u8, data, "\x1bOC"))) or
        (eqlKey(key, "left") and (std.mem.eql(u8, data, "\x1b[D") or std.mem.eql(u8, data, "\x1bOD"))) or
        (eqlKey(key, "home") and containsSequence(data, &.{ "\x1b[H", "\x1bOH", "\x1b[1~", "\x1b[7~" })) or
        (eqlKey(key, "end") and containsSequence(data, &.{ "\x1b[F", "\x1bOF", "\x1b[4~", "\x1b[8~" })) or
        (eqlKey(key, "insert") and std.mem.eql(u8, data, "\x1b[2~")) or
        (eqlKey(key, "delete") and std.mem.eql(u8, data, "\x1b[3~")) or
        ((eqlKey(key, "pageUp") or eqlKey(key, "pageup")) and containsSequence(data, &.{ "\x1b[5~", "\x1b[[5~" })) or
        ((eqlKey(key, "pageDown") or eqlKey(key, "pagedown")) and containsSequence(data, &.{ "\x1b[6~", "\x1b[[6~" })) or
        (eqlKey(key, "clear") and containsSequence(data, &.{ "\x1b[E", "\x1bOE" }));
}

fn matchesLegacyShift(data: []const u8, key: []const u8) bool {
    return (eqlKey(key, "up") and std.mem.eql(u8, data, "\x1b[a")) or
        (eqlKey(key, "down") and std.mem.eql(u8, data, "\x1b[b")) or
        (eqlKey(key, "right") and std.mem.eql(u8, data, "\x1b[c")) or
        (eqlKey(key, "left") and std.mem.eql(u8, data, "\x1b[d")) or
        (eqlKey(key, "insert") and std.mem.eql(u8, data, "\x1b[2$")) or
        (eqlKey(key, "delete") and std.mem.eql(u8, data, "\x1b[3$")) or
        ((eqlKey(key, "pageUp") or eqlKey(key, "pageup")) and std.mem.eql(u8, data, "\x1b[5$")) or
        ((eqlKey(key, "pageDown") or eqlKey(key, "pagedown")) and std.mem.eql(u8, data, "\x1b[6$")) or
        (eqlKey(key, "home") and std.mem.eql(u8, data, "\x1b[7$")) or
        (eqlKey(key, "end") and std.mem.eql(u8, data, "\x1b[8$")) or
        (eqlKey(key, "clear") and std.mem.eql(u8, data, "\x1b[e"));
}

fn matchesLegacyCtrl(data: []const u8, key: []const u8) bool {
    return (eqlKey(key, "up") and std.mem.eql(u8, data, "\x1bOa")) or
        (eqlKey(key, "down") and std.mem.eql(u8, data, "\x1bOb")) or
        (eqlKey(key, "right") and std.mem.eql(u8, data, "\x1bOc")) or
        (eqlKey(key, "left") and std.mem.eql(u8, data, "\x1bOd")) or
        (eqlKey(key, "insert") and std.mem.eql(u8, data, "\x1b[2^")) or
        (eqlKey(key, "delete") and std.mem.eql(u8, data, "\x1b[3^")) or
        ((eqlKey(key, "pageUp") or eqlKey(key, "pageup")) and std.mem.eql(u8, data, "\x1b[5^")) or
        ((eqlKey(key, "pageDown") or eqlKey(key, "pagedown")) and std.mem.eql(u8, data, "\x1b[6^")) or
        (eqlKey(key, "home") and std.mem.eql(u8, data, "\x1b[7^")) or
        (eqlKey(key, "end") and std.mem.eql(u8, data, "\x1b[8^")) or
        (eqlKey(key, "clear") and std.mem.eql(u8, data, "\x1bOe"));
}

fn functionKeyIndex(key: []const u8) ?usize {
    if (key.len < 2 or std.ascii.toLower(key[0]) != 'f') return null;
    const index = std.fmt.parseInt(usize, key[1..], 10) catch return null;
    return if (index >= 1 and index <= 12) index else null;
}

fn matchesLegacyFunction(data: []const u8, index: usize) bool {
    if (index < 1 or index > FUNCTION_KEY_TABLE.len) return false;
    return containsSequence(data, FUNCTION_KEY_TABLE[index - 1].sequences);
}

fn functionKeyName(index: usize) []const u8 {
    if (index < 1 or index > FUNCTION_KEY_TABLE.len) return "";
    return FUNCTION_KEY_TABLE[index - 1].name;
}

fn isPrintableKey(byte: u8) bool {
    const lower = std.ascii.toLower(byte);
    return (lower >= 'a' and lower <= 'z') or (byte >= '0' and byte <= '9') or isKnownSymbol(byte);
}

fn isLatinLetter(codepoint: i32) bool {
    return codepoint >= 'a' and codepoint <= 'z';
}

fn isDigitCodepoint(codepoint: i32) bool {
    return codepoint >= '0' and codepoint <= '9';
}

fn isKnownSymbol(codepoint: i32) bool {
    return switch (codepoint) {
        '`', '-', '=', '[', ']', '\\', ';', '\'', ',', '.', '/', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '|', '~', '{', '}', ':', '<', '>', '?' => true,
        else => false,
    };
}

fn eqlKey(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn containsAny(data: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, data, needle) != null) return true;
    }
    return false;
}

fn containsSequence(data: []const u8, sequences: []const []const u8) bool {
    for (sequences) |sequence| {
        if (std.mem.eql(u8, data, sequence)) return true;
    }
    return false;
}

test "keys match legacy and kitty sequences" {
    try std.testing.expect(matchesKey("\x03", "ctrl+c"));
    try std.testing.expect(matchesKey("\x1b[A", "up"));
    try std.testing.expect(matchesKey("\x1b[1;5D", "ctrl+left"));
    try std.testing.expect(matchesKey("\x1b[99;5u", "ctrl+c"));
}

test "keys parse and decode printable input" {
    const parsed = (try parseKeyAlloc(std.testing.allocator, "\x1b[1;5D")).?;
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqualStrings("ctrl+left", parsed);

    const decoded = (try decodePrintableKey(std.testing.allocator, "\x1b[65:65;2u")).?;
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("A", decoded);
}
