const std = @import("std");
const session_manager_mod = @import("../sessions/session_manager.zig");
const tui = @import("tui");
const overlay_table = @import("overlay_table.zig");

pub const SessionChoice = struct {
    path: []u8,
};

pub const SessionScope = enum { current, all };
pub const SessionSortMode = enum { threaded, recent, relevance };
pub const SessionNameFilter = enum { all, named };

pub const SessionOverlay = struct {
    title: []u8,
    hint: []u8,
    choices: []SessionChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,
    current_sessions: []session_manager_mod.SessionSearchInfo = &.{},
    all_sessions: []session_manager_mod.SessionSearchInfo = &.{},
    scope: SessionScope = .current,
    sort_mode: SessionSortMode = .threaded,
    name_filter: SessionNameFilter = .all,
    search: []u8 = &.{},
    show_path: bool = false,
    can_rename: bool = true,
    current_session_path: ?[]u8 = null,
    confirming_delete_path: ?[]u8 = null,
    rename_mode: bool = false,
    rename_target_path: ?[]u8 = null,
    rename_text: []u8 = &.{},

    // Table rendering data
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 28 }, .{ .fill = 1 } },

    pub fn deinit(self: *SessionOverlay, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.hint);
        for (self.choices) |choice| allocator.free(choice.path);
        allocator.free(self.choices);
        freeOwnedSelectItems(allocator, self.items);
        for (@constCast(self.current_sessions)) |*entry| entry.deinit(allocator);
        if (self.current_sessions.len > 0) allocator.free(@constCast(self.current_sessions));
        for (@constCast(self.all_sessions)) |*entry| entry.deinit(allocator);
        if (self.all_sessions.len > 0) allocator.free(@constCast(self.all_sessions));
        if (self.search.len > 0) allocator.free(self.search);
        if (self.current_session_path) |path| allocator.free(path);
        if (self.confirming_delete_path) |path| allocator.free(path);
        if (self.rename_target_path) |path| allocator.free(path);
        if (self.rename_text.len > 0) allocator.free(self.rename_text);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    current_session_path: ?[]const u8,
) !SessionOverlay {
    const current_sessions = try session_manager_mod.listAllSessionsUnder(allocator, io, session_dir);
    errdefer {
        for (@constCast(current_sessions)) |*entry| entry.deinit(allocator);
        allocator.free(@constCast(current_sessions));
    }

    const all_sessions = try cloneSessionSearchInfos(allocator, current_sessions);
    errdefer {
        for (@constCast(all_sessions)) |*entry| entry.deinit(allocator);
        allocator.free(@constCast(all_sessions));
    }

    var overlay = SessionOverlay{
        .title = try allocator.dupe(u8, ""),
        .hint = try allocator.dupe(u8, ""),
        .choices = try allocator.alloc(SessionChoice, 0),
        .items = try allocator.alloc(tui.SelectItem, 0),
        .list = .{ .items = &.{}, .max_visible = 12 },
        .current_sessions = current_sessions,
        .all_sessions = all_sessions,
        .current_session_path = if (current_session_path) |path| try allocator.dupe(u8, path) else null,
    };
    errdefer overlay.deinit(allocator);
    try refresh(allocator, &overlay);
    return overlay;
}

pub fn refresh(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    for (overlay.choices) |choice| allocator.free(choice.path);
    allocator.free(overlay.choices);
    freeOwnedSelectItems(allocator, overlay.items);
    allocator.free(overlay.title);
    allocator.free(overlay.hint);

    if (overlay.rename_mode) {
        overlay.title = try allocator.dupe(u8, "Rename Session");
        overlay.hint = try allocator.dupe(u8, "Enter save • Esc cancel");
        overlay.choices = try allocator.alloc(SessionChoice, 1);
        overlay.items = try allocator.alloc(tui.SelectItem, 1);
        overlay.choices[0] = .{ .path = try allocator.dupe(u8, overlay.rename_target_path orelse "") };
        overlay.items[0] = .{
            .value = try allocator.dupe(u8, "rename"),
            .label = try std.fmt.allocPrint(allocator, "Name: {s}", .{if (overlay.rename_text.len > 0) overlay.rename_text else ""}),
            .description = try allocator.dupe(u8, "Type a trimmed non-empty session name"),
        };
        overlay.list.items = overlay.items;
        overlay.list.selected_index = 0;
        overlay.list.max_visible = 1;
        return;
    }

    overlay.title = try std.fmt.allocPrint(
        allocator,
        "Session selector ({s})",
        .{if (overlay.scope == .current) "Current Folder" else "All"},
    );
    overlay.hint = try formatSessionOverlayHint(allocator, overlay);

    const source = if (overlay.scope == .all) overlay.all_sessions else overlay.current_sessions;
    const effective_sort: session_manager_mod.SessionSearchSortMode = switch (overlay.sort_mode) {
        .recent => .recent,
        .threaded, .relevance => .relevance,
    };
    const effective_name_filter: session_manager_mod.SessionSearchNameFilter = switch (overlay.name_filter) {
        .all => .all,
        .named => .named,
    };

    var ordered_indexes = std.ArrayList(usize).empty;
    defer ordered_indexes.deinit(allocator);

    const trimmed_search = std.mem.trim(u8, overlay.search, " \t\r\n");
    if (overlay.sort_mode == .threaded and trimmed_search.len == 0) {
        try appendThreadedSessionIndexes(allocator, source, effective_name_filter, &ordered_indexes);
    } else {
        const matches = try session_manager_mod.filterAndSortSessions(allocator, source, overlay.search, .{
            .sort_mode = effective_sort,
            .name_filter = effective_name_filter,
        });
        defer allocator.free(matches);
        for (matches) |match| try ordered_indexes.append(allocator, match.session_index);
    }

    const row_count = if (ordered_indexes.items.len == 0) @as(usize, 1) else ordered_indexes.items.len;
    const choices = try allocator.alloc(SessionChoice, row_count);
    errdefer {
        for (choices) |choice| allocator.free(choice.path);
        allocator.free(choices);
    }
    const items = try allocator.alloc(tui.SelectItem, row_count);
    errdefer freeOwnedSelectItems(allocator, items);

    if (ordered_indexes.items.len == 0) {
        choices[0] = .{ .path = try allocator.dupe(u8, "") };
        items[0] = .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, sessionOverlayEmptyMessage(overlay)),
            .description = try allocator.dupe(u8, if (overlay.search.len > 0) overlay.search else ""),
        };
    } else for (ordered_indexes.items, 0..) |session_index, row| {
        const session = source[session_index];
        choices[row] = .{ .path = try allocator.dupe(u8, session.path) };
        items[row] = .{
            .value = try allocator.dupe(u8, session.path),
            .label = try formatSessionOverlayLabel(allocator, overlay, session, if (session.parent_session != null and overlay.sort_mode == .threaded and trimmed_search.len == 0) 1 else 0),
            .description = try formatSessionOverlayDescription(allocator, overlay, session),
        };
    }

    overlay.choices = choices;
    overlay.items = items;
    overlay.list.items = items;
    overlay.list.selected_index = @min(overlay.list.selected_index, row_count - 1);
    overlay.list.max_visible = 12;

    overlay_table.freeTable(allocator, overlay.table_cells, overlay.table_rows);
    const built = try overlay_table.buildLabelDescriptionTable(allocator, overlay.items);
    overlay.table_cells = built.cells;
    overlay.table_rows = built.rows;
}

pub fn toggleScope(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    overlay.scope = if (overlay.scope == .current) .all else .current;
    try refresh(allocator, overlay);
}

pub fn toggleSort(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    overlay.sort_mode = switch (overlay.sort_mode) {
        .threaded => .recent,
        .recent => .relevance,
        .relevance => .threaded,
    };
    try refresh(allocator, overlay);
}

pub fn toggleNameFilter(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    overlay.name_filter = if (overlay.name_filter == .all) .named else .all;
    try refresh(allocator, overlay);
}

pub fn togglePath(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    overlay.show_path = !overlay.show_path;
    try refresh(allocator, overlay);
}

pub fn updateSearch(allocator: std.mem.Allocator, overlay: *SessionOverlay, next_search: []const u8) !void {
    const owned = try allocator.dupe(u8, next_search);
    if (overlay.search.len > 0) allocator.free(overlay.search);
    overlay.search = owned;
    try refresh(allocator, overlay);
}

pub fn moveSelection(overlay: *SessionOverlay, delta: isize) void {
    if (overlay.list.items.len == 0) {
        overlay.list.selected_index = 0;
        return;
    }
    const current: isize = @intCast(overlay.list.selectedIndex());
    const max_index: isize = @intCast(overlay.list.items.len - 1);
    const next = std.math.clamp(current + delta, 0, max_index);
    overlay.list.selected_index = @intCast(next);
}

pub fn beginDelete(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    const selected = selectedSessionChoice(overlay) orelse return;
    if (isCurrentSessionPath(allocator, overlay, selected.path)) return error.CannotDeleteCurrentSession;
    if (overlay.confirming_delete_path) |path| allocator.free(path);
    overlay.confirming_delete_path = try allocator.dupe(u8, selected.path);
    try refresh(allocator, overlay);
}

pub fn confirmDelete(allocator: std.mem.Allocator, io: std.Io, overlay: *SessionOverlay) !void {
    const path = overlay.confirming_delete_path orelse return;
    if (isCurrentSessionPath(allocator, overlay, path)) return error.CannotDeleteCurrentSession;
    std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try reloadSessions(allocator, io, overlay);
    allocator.free(path);
    overlay.confirming_delete_path = null;
    try refresh(allocator, overlay);
}

pub fn cancelDelete(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    if (overlay.confirming_delete_path) |path| allocator.free(path);
    overlay.confirming_delete_path = null;
    try refresh(allocator, overlay);
}

pub fn enterRename(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    if (!overlay.can_rename) return;
    const selected = selectedSessionChoice(overlay) orelse return;
    const session = selectedSessionInfo(overlay) orelse return;
    overlay.rename_mode = true;
    if (overlay.rename_target_path) |path| allocator.free(path);
    overlay.rename_target_path = try allocator.dupe(u8, selected.path);
    if (overlay.rename_text.len > 0) allocator.free(overlay.rename_text);
    overlay.rename_text = try allocator.dupe(u8, session.name orelse "");
    try refresh(allocator, overlay);
}

pub fn cancelRename(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    overlay.rename_mode = false;
    if (overlay.rename_target_path) |path| allocator.free(path);
    overlay.rename_target_path = null;
    if (overlay.rename_text.len > 0) allocator.free(overlay.rename_text);
    overlay.rename_text = &.{};
    try refresh(allocator, overlay);
}

pub fn confirmRename(allocator: std.mem.Allocator, io: std.Io, overlay: *SessionOverlay) !void {
    const target = overlay.rename_target_path orelse return;
    const trimmed = std.mem.trim(u8, overlay.rename_text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    var manager = try session_manager_mod.SessionManager.open(allocator, io, target, null);
    defer manager.deinit();
    _ = try manager.appendSessionInfo(trimmed);
    try reloadSessions(allocator, io, overlay);
    try cancelRename(allocator, overlay);
}

pub fn updateRenameText(allocator: std.mem.Allocator, overlay: *SessionOverlay, next_text: []const u8) !void {
    const owned = try allocator.dupe(u8, next_text);
    if (overlay.rename_text.len > 0) allocator.free(overlay.rename_text);
    overlay.rename_text = owned;
    try refresh(allocator, overlay);
}

pub fn cloneSessionSearchInfos(
    allocator: std.mem.Allocator,
    source: []const session_manager_mod.SessionSearchInfo,
) ![]session_manager_mod.SessionSearchInfo {
    const cloned = try allocator.alloc(session_manager_mod.SessionSearchInfo, source.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*entry| entry.deinit(allocator);
        allocator.free(cloned);
    }
    for (source, 0..) |entry, index| {
        cloned[index] = try cloneSessionSearchInfo(allocator, entry);
        initialized += 1;
    }
    return cloned;
}

fn cloneSessionSearchInfo(
    allocator: std.mem.Allocator,
    entry: session_manager_mod.SessionSearchInfo,
) !session_manager_mod.SessionSearchInfo {
    return .{
        .path = try allocator.dupe(u8, entry.path),
        .id = try allocator.dupe(u8, entry.id),
        .cwd = try allocator.dupe(u8, entry.cwd),
        .name = if (entry.name) |name| try allocator.dupe(u8, name) else null,
        .parent_session = if (entry.parent_session) |path| try allocator.dupe(u8, path) else null,
        .created_timestamp = try allocator.dupe(u8, entry.created_timestamp),
        .modified_timestamp = try allocator.dupe(u8, entry.modified_timestamp),
        .message_count = entry.message_count,
        .first_message = try allocator.dupe(u8, entry.first_message),
        .all_messages_text = try allocator.dupe(u8, entry.all_messages_text),
        .search_text = try allocator.dupe(u8, entry.search_text),
    };
}

fn formatSessionOverlayHint(allocator: std.mem.Allocator, overlay: *const SessionOverlay) ![]u8 {
    if (overlay.confirming_delete_path != null) return allocator.dupe(u8, "Delete session? Enter confirm • Esc cancel");
    const sort_label = switch (overlay.sort_mode) {
        .threaded => "Threaded",
        .recent => "Recent",
        .relevance => "Fuzzy",
    };
    const name_label = if (overlay.name_filter == .named) "Named" else "All";
    return std.fmt.allocPrint(
        allocator,
        "Tab scope • re:<pattern> regex • \"phrase\" exact • Sort: {s} • Name: {s} • Ctrl+S sort • Ctrl+N named • Ctrl+P path {s}{s}",
        .{
            sort_label,
            name_label,
            if (overlay.show_path) "on" else "off",
            if (overlay.can_rename) " • Ctrl+R rename" else "",
        },
    );
}

fn sessionOverlayEmptyMessage(overlay: *const SessionOverlay) []const u8 {
    if (overlay.name_filter == .named) return "No named sessions found";
    if (overlay.scope == .all) return "No sessions found";
    return "No sessions in current folder. Press Tab to view all.";
}

fn appendThreadedSessionIndexes(
    allocator: std.mem.Allocator,
    sessions: []const session_manager_mod.SessionSearchInfo,
    name_filter: session_manager_mod.SessionSearchNameFilter,
    out: *std.ArrayList(usize),
) !void {
    const appended = try allocator.alloc(bool, sessions.len);
    defer allocator.free(appended);
    @memset(appended, false);

    for (sessions, 0..) |session, index| {
        if (!sessionMatchesNameFilter(session, name_filter)) continue;
        if (session.parent_session) |parent| {
            if (findSessionIndexByCanonicalPath(allocator, sessions, parent)) |_| continue;
        }
        try appendThreadedSessionIndex(allocator, sessions, name_filter, index, appended, out);
    }
}

fn appendThreadedSessionIndex(
    allocator: std.mem.Allocator,
    sessions: []const session_manager_mod.SessionSearchInfo,
    name_filter: session_manager_mod.SessionSearchNameFilter,
    index: usize,
    appended: []bool,
    out: *std.ArrayList(usize),
) !void {
    if (appended[index]) return;
    if (!sessionMatchesNameFilter(sessions[index], name_filter)) return;
    appended[index] = true;
    try out.append(allocator, index);
    for (sessions, 0..) |candidate, child_index| {
        if (appended[child_index]) continue;
        const parent = candidate.parent_session orelse continue;
        if (pathsEqualCanonical(allocator, parent, sessions[index].path)) {
            try appendThreadedSessionIndex(allocator, sessions, name_filter, child_index, appended, out);
        }
    }
}

fn sessionMatchesNameFilter(session: session_manager_mod.SessionSearchInfo, filter: session_manager_mod.SessionSearchNameFilter) bool {
    return switch (filter) {
        .all => true,
        .named => if (session.name) |name| std.mem.trim(u8, name, &std.ascii.whitespace).len > 0 else false,
    };
}

fn findSessionIndexByCanonicalPath(
    allocator: std.mem.Allocator,
    sessions: []const session_manager_mod.SessionSearchInfo,
    path: []const u8,
) ?usize {
    for (sessions, 0..) |session, index| {
        if (pathsEqualCanonical(allocator, session.path, path)) return index;
    }
    return null;
}

fn pathsEqualCanonical(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) bool {
    const lhs_real = realpathAllocOrNull(allocator, lhs);
    defer if (lhs_real) |value| allocator.free(value);
    const rhs_real = realpathAllocOrNull(allocator, rhs);
    defer if (rhs_real) |value| allocator.free(value);
    const lhs_value = lhs_real orelse lhs;
    const rhs_value = rhs_real orelse rhs;
    return std.mem.eql(u8, lhs_value, rhs_value);
}

fn realpathAllocOrNull(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (@import("builtin").os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch return null;
    }
    const z_path = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return null;
    return allocator.dupe(u8, std.mem.span(resolved)) catch null;
}

fn formatSessionOverlayLabel(
    allocator: std.mem.Allocator,
    overlay: *const SessionOverlay,
    session: session_manager_mod.SessionSearchInfo,
    depth: usize,
) ![]u8 {
    _ = overlay;
    const display = if (session.name) |name| blk: {
        const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
        if (trimmed.len > 0) break :blk trimmed;
        break :blk session.first_message;
    } else session.first_message;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ indentationPrefixLiteral(depth), display });
}

fn indentationPrefixLiteral(depth: usize) []const u8 {
    return switch (@min(depth, 4)) {
        0 => "",
        1 => "└─ ",
        2 => "   └─ ",
        3 => "      └─ ",
        else => "         └─ ",
    };
}

fn formatSessionOverlayDescription(
    allocator: std.mem.Allocator,
    overlay: *const SessionOverlay,
    session: session_manager_mod.SessionSearchInfo,
) ![]u8 {
    if (overlay.show_path) {
        return std.fmt.allocPrint(allocator, "{s}{s}{s} • {d} messages • {s}", .{
            if (isCurrentSessionPath(allocator, overlay, session.path)) "current • " else "",
            if (session.name != null and std.mem.trim(u8, session.name.?, &std.ascii.whitespace).len > 0) "named • " else "",
            session.path,
            session.message_count,
            session.modified_timestamp,
        });
    }
    if (overlay.scope == .all and session.cwd.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}{s}{s} • {d} messages • {s}", .{
            if (isCurrentSessionPath(allocator, overlay, session.path)) "current • " else "",
            if (session.name != null and std.mem.trim(u8, session.name.?, &std.ascii.whitespace).len > 0) "named • " else "",
            session.cwd,
            session.message_count,
            session.modified_timestamp,
        });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}{d} messages • {s}", .{
        if (isCurrentSessionPath(allocator, overlay, session.path)) "current • " else "",
        if (session.name != null and std.mem.trim(u8, session.name.?, &std.ascii.whitespace).len > 0) "named • " else "",
        session.message_count,
        session.modified_timestamp,
    });
}

fn selectedSessionChoice(overlay: *const SessionOverlay) ?SessionChoice {
    if (overlay.choices.len == 0) return null;
    const index = overlay.list.selectedIndex();
    if (index >= overlay.choices.len) return null;
    const choice = overlay.choices[index];
    if (choice.path.len == 0) return null;
    return choice;
}

fn selectedSessionInfo(overlay: *const SessionOverlay) ?session_manager_mod.SessionSearchInfo {
    const choice = selectedSessionChoice(overlay) orelse return null;
    const source = if (overlay.scope == .all) overlay.all_sessions else overlay.current_sessions;
    for (source) |session| {
        if (std.mem.eql(u8, session.path, choice.path)) return session;
    }
    return null;
}

fn isCurrentSessionPath(allocator: std.mem.Allocator, overlay: *const SessionOverlay, path: []const u8) bool {
    const current = overlay.current_session_path orelse return false;
    return pathsEqualCanonical(allocator, current, path);
}

fn reloadSessions(allocator: std.mem.Allocator, io: std.Io, overlay: *SessionOverlay) !void {
    const root = if (overlay.current_sessions.len > 0) std.fs.path.dirname(overlay.current_sessions[0].path) orelse "." else ".";
    const next_current = try session_manager_mod.listAllSessionsUnder(allocator, io, root);
    errdefer {
        for (@constCast(next_current)) |*entry| entry.deinit(allocator);
        allocator.free(@constCast(next_current));
    }
    const next_all = try cloneSessionSearchInfos(allocator, next_current);
    errdefer {
        for (@constCast(next_all)) |*entry| entry.deinit(allocator);
        allocator.free(@constCast(next_all));
    }
    for (@constCast(overlay.current_sessions)) |*entry| entry.deinit(allocator);
    if (overlay.current_sessions.len > 0) allocator.free(@constCast(overlay.current_sessions));
    for (@constCast(overlay.all_sessions)) |*entry| entry.deinit(allocator);
    if (overlay.all_sessions.len > 0) allocator.free(@constCast(overlay.all_sessions));
    overlay.current_sessions = next_current;
    overlay.all_sessions = next_all;
}

const freeOwnedSelectItems = overlay_table.freeOwnedSelectItems;
