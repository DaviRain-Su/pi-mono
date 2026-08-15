const std = @import("std");

const ESC = "\x1b";
const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";

pub const StdinBufferOptions = struct {
    timeout_ms: u64 = 10,
};

pub const StdinBufferEvent = union(enum) {
    data: []u8,
    paste: []u8,

    pub fn deinit(self: StdinBufferEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .data, .paste => |text| allocator.free(text),
        }
    }
};

const ProcessError = std.mem.Allocator.Error;

pub const StdinBuffer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    paste_mode: bool = false,
    paste_buffer: std.ArrayList(u8) = .empty,
    pending_kitty_printable_codepoint: ?u21 = null,
    timeout_ms: u64 = 10,

    pub fn init(allocator: std.mem.Allocator, options: StdinBufferOptions) StdinBuffer {
        return .{ .allocator = allocator, .timeout_ms = options.timeout_ms };
    }

    pub fn deinit(self: *StdinBuffer) void {
        self.buffer.deinit(self.allocator);
        self.paste_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn process(self: *StdinBuffer, data: []const u8) ProcessError![]StdinBufferEvent {
        var events = std.ArrayList(StdinBufferEvent).empty;
        errdefer {
            for (events.items) |event| event.deinit(self.allocator);
            events.deinit(self.allocator);
        }

        var converted_buffer: [2]u8 = undefined;
        const str = if (data.len == 1 and data[0] > 127) blk: {
            converted_buffer[0] = 0x1b;
            converted_buffer[1] = data[0] - 128;
            break :blk converted_buffer[0..2];
        } else data;

        if (str.len == 0 and self.buffer.items.len == 0) {
            try self.emitDataSequence(&events, "");
            return events.toOwnedSlice(self.allocator);
        }

        try self.buffer.appendSlice(self.allocator, str);

        if (self.paste_mode) {
            try self.paste_buffer.appendSlice(self.allocator, self.buffer.items);
            self.buffer.clearRetainingCapacity();
            try self.drainPasteMode(&events);
            return events.toOwnedSlice(self.allocator);
        }

        if (std.mem.indexOf(u8, self.buffer.items, BRACKETED_PASTE_START)) |start_index| {
            if (start_index > 0) {
                const before_paste = self.buffer.items[0..start_index];
                const before_remainder = try self.extractCompleteSequences(before_paste, &events);
                defer self.allocator.free(before_remainder);
            }
            self.pending_kitty_printable_codepoint = null;
            try self.paste_buffer.appendSlice(self.allocator, self.buffer.items[start_index + BRACKETED_PASTE_START.len ..]);
            self.buffer.clearRetainingCapacity();
            self.paste_mode = true;
            try self.drainPasteMode(&events);
            return events.toOwnedSlice(self.allocator);
        }

        const remainder = try self.extractCompleteSequences(self.buffer.items, &events);
        defer self.allocator.free(remainder);
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, remainder);

        return events.toOwnedSlice(self.allocator);
    }

    pub fn flush(self: *StdinBuffer) ProcessError![]StdinBufferEvent {
        if (self.buffer.items.len == 0) return self.allocator.alloc(StdinBufferEvent, 0);
        const event = StdinBufferEvent{ .data = try self.allocator.dupe(u8, self.buffer.items) };
        self.buffer.clearRetainingCapacity();
        self.pending_kitty_printable_codepoint = null;
        const events = try self.allocator.alloc(StdinBufferEvent, 1);
        events[0] = event;
        return events;
    }

    pub fn clear(self: *StdinBuffer) void {
        self.buffer.clearRetainingCapacity();
        self.paste_buffer.clearRetainingCapacity();
        self.paste_mode = false;
        self.pending_kitty_printable_codepoint = null;
    }

    pub fn getBuffer(self: *const StdinBuffer) []const u8 {
        return self.buffer.items;
    }

    fn drainPasteMode(self: *StdinBuffer, events: *std.ArrayList(StdinBufferEvent)) ProcessError!void {
        const end_index = std.mem.indexOf(u8, self.paste_buffer.items, BRACKETED_PASTE_END) orelse return;
        const pasted = self.paste_buffer.items[0..end_index];
        const remaining = self.paste_buffer.items[end_index + BRACKETED_PASTE_END.len ..];
        try events.append(self.allocator, .{ .paste = try self.allocator.dupe(u8, pasted) });

        const remaining_owned = try self.allocator.dupe(u8, remaining);
        defer self.allocator.free(remaining_owned);
        self.paste_buffer.clearRetainingCapacity();
        self.paste_mode = false;
        self.pending_kitty_printable_codepoint = null;

        if (remaining_owned.len > 0) {
            const more = try self.process(remaining_owned);
            defer self.allocator.free(more);
            try events.appendSlice(self.allocator, more);
        }
    }

    fn extractCompleteSequences(self: *StdinBuffer, input: []const u8, events: *std.ArrayList(StdinBufferEvent)) ProcessError![]u8 {
        var pos: usize = 0;
        while (pos < input.len) {
            const remaining = input[pos..];
            if (std.mem.startsWith(u8, remaining, ESC)) {
                var seq_end: usize = 1;
                while (seq_end <= remaining.len) : (seq_end += 1) {
                    const candidate = remaining[0..seq_end];
                    switch (isCompleteSequence(candidate)) {
                        .complete => {
                            // Mirror TS fix: WezTerm with enable_kitty_keyboard
                            // sends Escape press as raw '\x1b' and release as a
                            // full Kitty CSI-u, concatenated as '\x1b\x1b[27;...u'.
                            // The buffer would otherwise treat '\x1b\x1b' as a
                            // complete meta-key sequence (Alt+ESC), leaving the
                            // following CSI to be typed as plain text. If the
                            // character after '\x1b\x1b' would begin a new escape
                            // sequence ([, ], O, P, _), emit only the first ESC
                            // and restart parsing from the second.
                            if (candidate.len == 2 and candidate[0] == 0x1b and candidate[1] == 0x1b and seq_end < remaining.len) {
                                const next_char = remaining[seq_end];
                                if (next_char == '[' or next_char == ']' or next_char == 'O' or next_char == 'P' or next_char == '_') {
                                    try self.emitDataSequence(events, remaining[0..1]);
                                    pos += 1;
                                    break;
                                }
                            }
                            try self.emitDataSequence(events, candidate);
                            pos += seq_end;
                            break;
                        },
                        .incomplete => {},
                        .not_escape => {
                            try self.emitDataSequence(events, candidate);
                            pos += seq_end;
                            break;
                        },
                    }
                } else {
                    return self.allocator.dupe(u8, remaining);
                }
            } else {
                try self.emitDataSequence(events, remaining[0..1]);
                pos += 1;
            }
        }
        return self.allocator.alloc(u8, 0);
    }

    fn emitDataSequence(self: *StdinBuffer, events: *std.ArrayList(StdinBufferEvent), sequence: []const u8) ProcessError!void {
        if (sequence.len == 1) {
            const raw_codepoint: u21 = sequence[0];
            if (self.pending_kitty_printable_codepoint) |pending| {
                if (raw_codepoint == pending) {
                    self.pending_kitty_printable_codepoint = null;
                    return;
                }
            }
        }
        self.pending_kitty_printable_codepoint = parseUnmodifiedKittyPrintableCodepoint(sequence);
        try events.append(self.allocator, .{ .data = try self.allocator.dupe(u8, sequence) });
    }
};

const SequenceStatus = enum { complete, incomplete, not_escape };

fn isCompleteSequence(data: []const u8) SequenceStatus {
    if (!std.mem.startsWith(u8, data, ESC)) return .not_escape;
    if (data.len == 1) return .incomplete;
    const after_esc = data[1..];
    if (std.mem.startsWith(u8, after_esc, "[")) {
        if (std.mem.startsWith(u8, after_esc, "[M")) return if (data.len >= 6) .complete else .incomplete;
        return isCompleteCsiSequence(data);
    }
    if (std.mem.startsWith(u8, after_esc, "]")) return isCompleteDelimitedSequence(data, "\x1b]", true);
    if (std.mem.startsWith(u8, after_esc, "P")) return isCompleteDelimitedSequence(data, "\x1bP", false);
    if (std.mem.startsWith(u8, after_esc, "_")) return isCompleteDelimitedSequence(data, "\x1b_", false);
    if (std.mem.startsWith(u8, after_esc, "O")) return if (after_esc.len >= 2) .complete else .incomplete;
    if (after_esc.len == 1) return .complete;
    return .complete;
}

fn isCompleteCsiSequence(data: []const u8) SequenceStatus {
    if (!std.mem.startsWith(u8, data, "\x1b[")) return .complete;
    if (data.len < 3) return .incomplete;
    const payload = data[2..];
    const last = payload[payload.len - 1];
    if (last < 0x40 or last > 0x7e) return .incomplete;
    if (std.mem.startsWith(u8, payload, "<")) {
        if (last != 'M' and last != 'm') return .incomplete;
        return if (mousePayloadComplete(payload[1 .. payload.len - 1])) .complete else .incomplete;
    }
    return .complete;
}

fn isCompleteDelimitedSequence(data: []const u8, prefix: []const u8, allow_bel: bool) SequenceStatus {
    if (!std.mem.startsWith(u8, data, prefix)) return .complete;
    if (std.mem.endsWith(u8, data, "\x1b\\")) return .complete;
    if (allow_bel and std.mem.endsWith(u8, data, "\x07")) return .complete;
    return .incomplete;
}

fn mousePayloadComplete(payload: []const u8) bool {
    var parts = std.mem.splitScalar(u8, payload, ';');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |byte| {
            if (!std.ascii.isDigit(byte)) return false;
        }
        count += 1;
    }
    return count == 3;
}

fn parseUnmodifiedKittyPrintableCodepoint(sequence: []const u8) ?u21 {
    if (!std.mem.startsWith(u8, sequence, "\x1b[") or !std.mem.endsWith(u8, sequence, "u")) return null;
    const payload = sequence[2 .. sequence.len - 1];
    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse payload.len;
    const codepoint = std.fmt.parseInt(u21, payload[0..colon], 10) catch return null;
    return if (codepoint >= 32) codepoint else null;
}

test "StdinBuffer joins partial escape sequences and emits paste" {
    var buffer = StdinBuffer.init(std.testing.allocator, .{});
    defer buffer.deinit();

    const events = try buffer.process("\x1b[<35");
    defer {
        for (events) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 0), events.len);

    const events2 = try buffer.process(";20;5m");
    defer {
        for (events2) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events2);
    }
    try std.testing.expectEqual(@as(usize, 1), events2.len);
    try std.testing.expectEqualStrings("\x1b[<35;20;5m", events2[0].data);

    const events3 = try buffer.process("\x1b[200~hello\x1b[201~");
    defer {
        for (events3) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events3);
    }
    try std.testing.expectEqual(@as(usize, 1), events3.len);
    try std.testing.expectEqualStrings("hello", events3[0].paste);
}

test "StdinBuffer splits WezTerm kitty ESC+ESC+CSI-u into ESC and Kitty release" {
    var buffer = StdinBuffer.init(std.testing.allocator, .{});
    defer buffer.deinit();

    // WezTerm with enable_kitty_keyboard concatenates Escape press (\x1b)
    // and release (\x1b[27;129:3u with num_lock).
    const events = try buffer.process("\x1b\x1b[27;129:3u");
    defer {
        for (events) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("\x1b", events[0].data);
    try std.testing.expectEqualStrings("\x1b[27;129:3u", events[1].data);
}

test "StdinBuffer splits WezTerm kitty ESC+ESC+CSI-u without num_lock" {
    var buffer = StdinBuffer.init(std.testing.allocator, .{});
    defer buffer.deinit();

    const events = try buffer.process("\x1b\x1b[27;1:3u");
    defer {
        for (events) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("\x1b", events[0].data);
    try std.testing.expectEqualStrings("\x1b[27;1:3u", events[1].data);
}

test "StdinBuffer preserves ctrl+alt+[ when ESC+ESC has no trailing CSI" {
    var buffer = StdinBuffer.init(std.testing.allocator, .{});
    defer buffer.deinit();

    // Without a following CSI/OSC/SS3/DCS/APC start, '\x1b\x1b' must still
    // emit as a meta-key sequence (Ctrl+Alt+[).
    const events = try buffer.process("\x1b\x1b");
    defer {
        for (events) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("\x1b\x1b", events[0].data);
}
