const std = @import("std");
const tui = @import("tui");
const keybinding_schema = @import("shared").keybinding_schema;

pub const KeySpec = keybinding_schema.KeySpec;

pub fn keySpecMatches(spec: KeySpec, key: tui.Key, modifiers: tui.keys.KeyModifiers) bool {
    return switch (spec) {
        .ctrl => |value| switch (key) {
            .ctrl => |pressed| pressed == value and !modifiers.hasAny(),
            else => false,
        },
        .ctrl_alt => |value| switch (key) {
            .printable => |pk| pk.slice().len == 1 and
                std.ascii.toLower(pk.slice()[0]) == value and
                modifiers.ctrl and modifiers.alt and !modifiers.shift and !modifiers.super,
            .ctrl => |pressed| pressed == value and modifiers.alt and !modifiers.shift and !modifiers.super,
            else => false,
        },
        .alt => |value| switch (key) {
            .printable => |pk| pk.slice().len == 1 and
                std.ascii.toLower(pk.slice()[0]) == value and
                modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
            else => false,
        },
        .escape => key == .escape and !modifiers.hasAny(),
        .enter => key == .enter and !modifiers.hasAny(),
        .shift_enter => key == .enter and modifiers.shift and !modifiers.alt and !modifiers.ctrl and !modifiers.super,
        .tab => key == .tab and !modifiers.hasAny(),
        .shift_tab => key == .shift_tab and !modifiers.hasAny(),
        .alt_enter => key == .enter and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
        .alt_up => key == .up and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
        .alt_down => key == .down and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
        .alt_left => key == .left and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
        .alt_right => key == .right and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
        .ctrl_left => key == .ctrl_left and !modifiers.hasAny(),
        .ctrl_right => key == .ctrl_right and !modifiers.hasAny(),
        .ctrl_end => key == .ctrl_end and !modifiers.hasAny(),
        .ctrl_backspace => key == .backspace and modifiers.ctrl and !modifiers.shift and !modifiers.alt and !modifiers.super,
        .shift_char => |letter| blk: {
            break :blk switch (key) {
                .printable => |pk| pk.slice().len == 1 and
                    (pk.slice()[0] == letter or pk.slice()[0] == std.ascii.toUpper(letter)) and
                    modifiers.shift and !modifiers.ctrl and !modifiers.alt and !modifiers.super,
                else => false,
            };
        },
        .shift_ctrl_char => |letter| blk: {
            break :blk switch (key) {
                .printable => |pk| pk.slice().len == 1 and
                    (pk.slice()[0] == letter or pk.slice()[0] == std.ascii.toUpper(letter)) and
                    modifiers.shift and modifiers.ctrl and !modifiers.alt and !modifiers.super,
                .ctrl => |c| c == letter and modifiers.shift and !modifiers.alt and !modifiers.super,
                else => false,
            };
        },
        .up => key == .up and !modifiers.hasAny(),
        .down => key == .down and !modifiers.hasAny(),
        .left => key == .left and !modifiers.hasAny(),
        .right => key == .right and !modifiers.hasAny(),
        .home => key == .home and !modifiers.hasAny(),
        .end => key == .end and !modifiers.hasAny(),
        .page_up => key == .page_up and !modifiers.hasAny(),
        .page_down => key == .page_down and !modifiers.hasAny(),
        .backspace => key == .backspace and !modifiers.hasAny(),
        .delete => key == .delete and !modifiers.hasAny(),
        .alt_backspace => key == .backspace and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
        .alt_delete => key == .delete and modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super,
    };
}

test "key matcher handles shifted printable keys" {
    const spec = KeySpec{ .shift_char = 'l' };
    try std.testing.expect(keySpecMatches(
        spec,
        .{ .printable = tui.keys.PrintableKey.fromSlice("L") },
        .{ .shift = true },
    ));
}
