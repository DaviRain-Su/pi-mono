const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const config_mod = @import("../config/config.zig");
const provider_config = @import("../providers/provider_config.zig");
const shared = @import("shared.zig");
const tui = @import("tui");
const overlay_table = @import("overlay_table.zig");

const configuredCredentials = shared.configuredCredentials;

pub const ModelChoice = struct {
    provider: []u8,
    model_id: []u8,
};

pub const ModelScope = enum { all, scoped };

pub const ModelOverlay = struct {
    title: []const u8 = "Model selector",
    hint: []u8,
    choices: []ModelChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,
    all_models: []provider_config.AvailableModel = &.{},
    scoped_models: []provider_config.AvailableModel = &.{},
    scope: ModelScope = .all,
    search: []u8 = &.{},
    current_provider: []u8 = &.{},
    current_model_id: []u8 = &.{},
    config_error: ?[]u8 = null,

    // Table rendering data (parallel to items, excluding error/empty rows)
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 2 }, .{ .length = 14 }, .{ .fill = 1 }, .{ .length = 12 } },

    pub fn deinit(self: *ModelOverlay, allocator: std.mem.Allocator) void {
        allocator.free(self.hint);
        if (self.search.len > 0) allocator.free(self.search);
        if (self.current_provider.len > 0) allocator.free(self.current_provider);
        if (self.current_model_id.len > 0) allocator.free(self.current_model_id);
        if (self.config_error) |message| allocator.free(message);
        if (self.all_models.len > 0) allocator.free(self.all_models);
        if (self.scoped_models.len > 0) allocator.free(self.scoped_models);
        freeModelChoices(allocator, self.choices);
        freeOwnedSelectItems(allocator, self.items);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub const ScopedModelChoice = struct {
    full_id: []u8,
    provider: []u8,
    model_id: []u8,
};

pub const ScopedModelsOverlay = struct {
    hint: []u8,
    choices: []ScopedModelChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,
    all_models: []provider_config.AvailableModel,
    all_ids: [][]u8,
    enabled_ids: ?[][]u8,
    search: []u8 = &.{},
    dirty: bool = false,

    // Table rendering data (parallel to choices, excluding empty row)
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 2 }, .{ .length = 3 }, .{ .fill = 1 }, .{ .length = 12 } },

    pub fn deinit(self: *ScopedModelsOverlay, allocator: std.mem.Allocator) void {
        allocator.free(self.hint);
        freeScopedModelChoices(allocator, self.choices);
        freeOwnedSelectItems(allocator, self.items);
        if (self.all_models.len > 0) allocator.free(self.all_models);
        freeOwnedStrings(allocator, self.all_ids);
        if (self.enabled_ids) |ids| freeOwnedStrings(allocator, ids);
        if (self.search.len > 0) allocator.free(self.search);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !ModelOverlay {
    return loadWithSearch(allocator, env_map, current_model, current_provider, model_patterns, runtime_config, null);
}

pub fn loadWithSearch(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
    initial_search: ?[]const u8,
) !ModelOverlay {
    const search = if (initial_search) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    const all_models = try loadSelectableModels(allocator, env_map, current_model, current_provider, null, runtime_config);
    errdefer allocator.free(all_models);
    const scoped_models = if (model_patterns) |patterns|
        try loadSelectableModels(allocator, env_map, current_model, current_provider, patterns, runtime_config)
    else
        try allocator.alloc(provider_config.AvailableModel, 0);
    errdefer allocator.free(scoped_models);

    var overlay = ModelOverlay{
        .title = "Model selector",
        .hint = try allocator.dupe(u8, ""),
        .choices = try allocator.alloc(ModelChoice, 0),
        .items = try allocator.alloc(tui.SelectItem, 0),
        .list = .{ .items = &.{}, .max_visible = 12 },
        .all_models = all_models,
        .scoped_models = scoped_models,
        .scope = if (scoped_models.len > 0) .scoped else .all,
        .search = try allocator.dupe(u8, search),
        .current_provider = try allocator.dupe(u8, current_model.provider),
        .current_model_id = try allocator.dupe(u8, current_model.id),
        .config_error = try firstModelConfigError(allocator, runtime_config),
    };
    errdefer overlay.deinit(allocator);
    try refresh(allocator, &overlay);
    return overlay;
}

pub fn refresh(allocator: std.mem.Allocator, overlay: *ModelOverlay) !void {
    freeModelChoices(allocator, overlay.choices);
    freeOwnedSelectItems(allocator, overlay.items);
    allocator.free(overlay.hint);

    const active_models = if (overlay.scope == .scoped and overlay.scoped_models.len > 0) overlay.scoped_models else overlay.all_models;
    var visible_models = std.ArrayList(provider_config.AvailableModel).empty;
    defer visible_models.deinit(allocator);
    for (active_models) |entry| {
        if (overlay.search.len == 0 or availableModelMatchesSearch(entry, overlay.search)) {
            try visible_models.append(allocator, entry);
        }
    }

    const has_empty_result = visible_models.items.len == 0;
    const error_row_count: usize = if (overlay.config_error != null) 1 else 0;
    const row_count = if (has_empty_result) 1 + error_row_count else visible_models.items.len + error_row_count;
    const choices = try allocator.alloc(ModelChoice, row_count);
    errdefer freeModelChoices(allocator, choices);
    const items = try allocator.alloc(tui.SelectItem, row_count);
    errdefer freeOwnedSelectItems(allocator, items);

    var selected_index: usize = 0;
    var out_index: usize = 0;
    if (has_empty_result) {
        choices[out_index] = .{
            .provider = try allocator.dupe(u8, ""),
            .model_id = try allocator.dupe(u8, ""),
        };
        items[out_index] = .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No matching models"),
            .description = if (overlay.search.len > 0)
                try std.fmt.allocPrint(allocator, "Search: {s}", .{overlay.search})
            else
                try allocator.dupe(u8, "No models available"),
        };
        out_index += 1;
    } else for (visible_models.items, 0..) |entry, index| {
        const provider_changed = index == 0 or !std.mem.eql(u8, visible_models.items[index - 1].provider, entry.provider);
        const label = try formatModelOverlayLabelWithCurrent(allocator, entry, provider_changed, overlay.current_provider, overlay.current_model_id);
        errdefer allocator.free(label);
        const description = try formatModelOverlayDescription(allocator, entry);
        errdefer allocator.free(description);
        choices[out_index] = .{
            .provider = try allocator.dupe(u8, entry.provider),
            .model_id = try allocator.dupe(u8, entry.model_id),
        };
        items[out_index] = .{
            .value = try allocator.dupe(u8, entry.model_id),
            .label = label,
            .description = description,
        };
        if (std.mem.eql(u8, entry.provider, overlay.current_provider) and std.mem.eql(u8, entry.model_id, overlay.current_model_id)) {
            selected_index = out_index;
        }
        out_index += 1;
    }

    if (overlay.config_error) |message| {
        choices[out_index] = .{
            .provider = try allocator.dupe(u8, ""),
            .model_id = try allocator.dupe(u8, ""),
        };
        items[out_index] = .{
            .value = try allocator.dupe(u8, "error"),
            .label = try std.fmt.allocPrint(allocator, "Error: {s}", .{message}),
            .description = try allocator.dupe(u8, "Valid models remain selectable"),
        };
    }

    overlay.choices = choices;
    overlay.items = items;
    overlay.list.items = items;
    overlay.list.selected_index = selected_index;
    overlay.list.max_visible = 12;

    // Build table rows (only for actual model entries, not error/empty rows)
    overlay_table.freeTable(allocator, overlay.table_cells, overlay.table_rows);
    overlay.table_cells = &[_]tui.TableCell{};
    overlay.table_rows = &[_]tui.TableRow{};

    if (!has_empty_result and visible_models.items.len > 0) {
        const col_count: usize = 4;
        const table_row_count = visible_models.items.len;
        const total_cells = table_row_count * col_count;

        const table_cells = try allocator.alloc(tui.TableCell, total_cells);
        errdefer allocator.free(table_cells);

        const table_rows = try allocator.alloc(tui.TableRow, table_row_count);
        errdefer allocator.free(table_rows);

        for (visible_models.items, 0..) |entry, index| {
            const is_current = std.mem.eql(u8, entry.provider, overlay.current_provider) and
                std.mem.eql(u8, entry.model_id, overlay.current_model_id);
            const cell_start = index * col_count;

            table_cells[cell_start] = .{ .text = if (is_current) "✓" else " " };
            table_cells[cell_start + 1] = .{ .text = provider_config.providerDisplayName(entry.provider) };
            table_cells[cell_start + 2] = .{ .text = entry.display_name };
            table_cells[cell_start + 3] = .{ .text = provider_config.providerAuthStatusLabel(entry.auth_status) };

            table_rows[index] = .{ .cells = table_cells[cell_start .. cell_start + col_count] };
        }

        overlay.table_cells = table_cells;
        overlay.table_rows = table_rows;
        overlay.table_state = .{ .selected_index = selected_index };
    }

    overlay.hint = try formatModelOverlayHint(allocator, overlay);
}

pub fn toggleScope(allocator: std.mem.Allocator, overlay: *ModelOverlay) !void {
    if (overlay.scoped_models.len == 0) return;
    overlay.scope = if (overlay.scope == .all) .scoped else .all;
    try refresh(allocator, overlay);
}

pub fn updateSearch(allocator: std.mem.Allocator, overlay: *ModelOverlay, next_search: []const u8) !void {
    const owned = try allocator.dupe(u8, next_search);
    if (overlay.search.len > 0) allocator.free(overlay.search);
    overlay.search = owned;
    try refresh(allocator, overlay);
}

pub fn loadScoped(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    enabled_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !ScopedModelsOverlay {
    const all_models = try loadSelectableModels(allocator, env_map, current_model, current_provider, null, runtime_config);
    errdefer allocator.free(all_models);
    if (all_models.len == 0) return error.NoScopedModelsAvailable;

    const all_ids = try buildAllModelIds(allocator, all_models);
    errdefer freeOwnedStrings(allocator, all_ids);
    const enabled_ids = if (enabled_patterns) |patterns|
        try cloneEnabledModelIds(allocator, patterns)
    else
        null;
    errdefer if (enabled_ids) |ids| freeOwnedStrings(allocator, ids);

    var overlay = ScopedModelsOverlay{
        .hint = try allocator.dupe(u8, ""),
        .choices = try allocator.alloc(ScopedModelChoice, 0),
        .items = try allocator.alloc(tui.SelectItem, 0),
        .list = .{ .items = &.{}, .max_visible = 8 },
        .all_models = all_models,
        .all_ids = all_ids,
        .enabled_ids = enabled_ids,
    };
    errdefer overlay.deinit(allocator);
    try refreshScoped(allocator, &overlay);
    return overlay;
}

pub fn refreshScoped(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    freeScopedModelChoices(allocator, overlay.choices);
    freeOwnedSelectItems(allocator, overlay.items);
    allocator.free(overlay.hint);

    var ordered = std.ArrayList(usize).empty;
    defer ordered.deinit(allocator);
    try appendOrderedModelIndexes(allocator, &ordered, overlay);

    var filtered = std.ArrayList(usize).empty;
    defer filtered.deinit(allocator);
    for (ordered.items) |model_index| {
        const model = overlay.all_models[model_index];
        if (overlay.search.len == 0 or availableModelMatchesSearch(model, overlay.search)) {
            try filtered.append(allocator, model_index);
        }
    }

    const has_empty_result = filtered.items.len == 0;
    const row_count = if (has_empty_result) 1 else filtered.items.len;
    const choices = try allocator.alloc(ScopedModelChoice, row_count);
    errdefer freeScopedModelChoices(allocator, choices);
    const items = try allocator.alloc(tui.SelectItem, row_count);
    errdefer freeOwnedSelectItems(allocator, items);

    if (has_empty_result) {
        choices[0] = .{
            .full_id = try allocator.dupe(u8, ""),
            .provider = try allocator.dupe(u8, ""),
            .model_id = try allocator.dupe(u8, ""),
        };
        items[0] = .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No matching models"),
            .description = try allocator.dupe(u8, "No models match the current search"),
        };
    } else for (filtered.items, 0..) |model_index, row| {
        const model = overlay.all_models[model_index];
        const full_id = try formatModelFullId(allocator, model);
        errdefer allocator.free(full_id);
        const enabled = scopedModelIsEnabled(overlay.enabled_ids, full_id);
        const label = try std.fmt.allocPrint(
            allocator,
            "{s} {s} [{s}]{s}",
            .{
                if (row == overlay.list.selectedIndex()) "→" else " ",
                model.display_name,
                model.provider,
                if (overlay.enabled_ids == null) "" else if (enabled) " ✓" else " ✗",
            },
        );
        errdefer allocator.free(label);
        choices[row] = .{
            .full_id = full_id,
            .provider = try allocator.dupe(u8, model.provider),
            .model_id = try allocator.dupe(u8, model.model_id),
        };
        items[row] = .{
            .value = try allocator.dupe(u8, full_id),
            .label = label,
            .description = try std.fmt.allocPrint(allocator, "{s} • {s}", .{ full_id, provider_config.providerAuthStatusLabel(model.auth_status) }),
        };
    }

    overlay.choices = choices;
    overlay.items = items;
    overlay.list.items = items;
    overlay.list.selected_index = @min(overlay.list.selected_index, row_count - 1);
    overlay.list.max_visible = 8;

    // Build table rows (only for actual model entries, not empty row)
    overlay_table.freeTable(allocator, overlay.table_cells, overlay.table_rows);
    overlay.table_cells = &[_]tui.TableCell{};
    overlay.table_rows = &[_]tui.TableRow{};

    if (!has_empty_result and filtered.items.len > 0) {
        const col_count: usize = 4;
        const table_row_count = filtered.items.len;
        const total_cells = table_row_count * col_count;

        const table_cells = try allocator.alloc(tui.TableCell, total_cells);
        errdefer allocator.free(table_cells);

        const table_rows = try allocator.alloc(tui.TableRow, table_row_count);
        errdefer allocator.free(table_rows);

        for (filtered.items, 0..) |model_index, index| {
            const model = overlay.all_models[model_index];
            const full_id = try formatModelFullId(allocator, model);
            defer allocator.free(full_id);
            const enabled = scopedModelIsEnabled(overlay.enabled_ids, full_id);
            const cell_start = index * col_count;

            table_cells[cell_start] = .{ .text = if (index == overlay.list.selected_index) ">" else " " };
            table_cells[cell_start + 1] = .{ .text = if (overlay.enabled_ids == null) "" else if (enabled) "✓" else "✗" };
            table_cells[cell_start + 2] = .{ .text = model.display_name };
            table_cells[cell_start + 3] = .{ .text = provider_config.providerDisplayName(model.provider) };

            table_rows[index] = .{ .cells = table_cells[cell_start .. cell_start + col_count] };
        }

        overlay.table_cells = table_cells;
        overlay.table_rows = table_rows;
        overlay.table_state = .{ .selected_index = overlay.list.selected_index };
    }

    overlay.hint = try formatScopedModelsHint(allocator, overlay);
}

pub fn updateScopedSearch(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay, next_search: []const u8) !void {
    const owned = try allocator.dupe(u8, next_search);
    if (overlay.search.len > 0) allocator.free(overlay.search);
    overlay.search = owned;
    try refreshScoped(allocator, overlay);
}

pub fn toggleScopedModel(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    const choice = selectedScopedChoice(overlay) orelse return;
    try setEnabledIds(allocator, overlay, try toggledEnabledIds(allocator, overlay.enabled_ids, choice.full_id));
}

pub fn enableScopedModels(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    const targets = try currentScopedTargetIds(allocator, overlay);
    defer freeOwnedStrings(allocator, targets);
    try setEnabledIds(allocator, overlay, try enabledAllIds(allocator, overlay.enabled_ids, overlay.all_ids, targets));
}

pub fn clearScopedModels(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    const targets = try currentScopedTargetIds(allocator, overlay);
    defer freeOwnedStrings(allocator, targets);
    try setEnabledIds(allocator, overlay, try clearedAllIds(allocator, overlay.enabled_ids, overlay.all_ids, targets, overlay.search.len > 0));
}

pub fn toggleScopedProvider(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    const choice = selectedScopedChoice(overlay) orelse return;
    var provider_ids = std.ArrayList([]u8).empty;
    defer {
        for (provider_ids.items) |id| allocator.free(id);
        provider_ids.deinit(allocator);
    }
    for (overlay.all_models) |model| {
        if (!std.mem.eql(u8, model.provider, choice.provider)) continue;
        try provider_ids.append(allocator, try formatModelFullId(allocator, model));
    }
    const all_enabled = blk: {
        for (provider_ids.items) |id| {
            if (!scopedModelIsEnabled(overlay.enabled_ids, id)) break :blk false;
        }
        break :blk true;
    };
    const next = if (all_enabled)
        try clearedAllIds(allocator, overlay.enabled_ids, overlay.all_ids, provider_ids.items, true)
    else
        try enabledAllIds(allocator, overlay.enabled_ids, overlay.all_ids, provider_ids.items);
    try setEnabledIds(allocator, overlay, next);
}

pub fn reorderScopedModel(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay, delta: isize) !void {
    if (overlay.enabled_ids == null) return;
    const choice = selectedScopedChoice(overlay) orelse return;
    const ids = overlay.enabled_ids.?;
    const index = indexOfString(ids, choice.full_id) orelse return;
    if (delta < 0 and index == 0) return;
    if (delta > 0 and index + 1 >= ids.len) return;
    const swap_index: usize = if (delta < 0) index - 1 else index + 1;
    std.mem.swap([]u8, &ids[index], &ids[swap_index]);
    overlay.dirty = true;
    overlay.list.selected_index = if (delta < 0) overlay.list.selectedIndex() -| 1 else overlay.list.selectedIndex() + 1;
    try refreshScoped(allocator, overlay);
}

pub fn loadSelectableModels(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) ![]provider_config.AvailableModel {
    const available = try provider_config.listAvailableModels(allocator, env_map, current_model, configuredCredentials(runtime_config));
    errdefer allocator.free(available);

    if (current_provider) |resolved_provider| {
        for (available) |*entry| {
            if (!std.mem.eql(u8, entry.provider, resolved_provider.model.provider)) continue;
            entry.auth_status = resolved_provider.auth_status;
            entry.available = resolved_provider.auth_status != .missing;
        }
    }

    const configured = try provider_config.filterConfiguredModels(allocator, available);
    allocator.free(available);
    errdefer allocator.free(configured);

    const patterns = model_patterns orelse return configured;
    const filtered = try provider_config.filterAvailableModels(allocator, configured, patterns);
    allocator.free(configured);
    return filtered;
}

fn formatModelOverlayHint(allocator: std.mem.Allocator, overlay: *const ModelOverlay) ![]u8 {
    if (overlay.scoped_models.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            "Scope: {s} • Tab scope • Search: {s} • Up/Down move • Enter select • Esc cancel",
            .{ if (overlay.scope == .scoped) "scoped" else "all", if (overlay.search.len > 0) overlay.search else "" },
        );
    }
    if (overlay.search.len > 0) {
        return std.fmt.allocPrint(allocator, "Search: {s} • Up/Down move • Enter select • Esc cancel", .{overlay.search});
    }
    return allocator.dupe(u8, "Up/Down move • Enter select • Esc cancel");
}

fn availableModelMatchesSearch(entry: provider_config.AvailableModel, search: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, search, " \t\r\n");
    var saw_token = false;
    while (tokens.next()) |token| {
        saw_token = true;
        if (!availableModelMatchesSearchToken(entry, token)) return false;
    }
    return saw_token;
}

fn availableModelMatchesSearchToken(entry: provider_config.AvailableModel, search: []const u8) bool {
    if (string_utils.containsIgnoreCase(entry.model_id, search)) return true;
    if (string_utils.containsIgnoreCase(entry.display_name, search)) return true;
    if (string_utils.containsIgnoreCase(entry.provider, search)) return true;

    var provider_model_buffer: [512]u8 = undefined;
    const provider_model = std.fmt.bufPrint(&provider_model_buffer, "{s}/{s}", .{ entry.provider, entry.model_id }) catch return false;
    return string_utils.containsIgnoreCase(provider_model, search);
}

fn firstModelConfigError(allocator: std.mem.Allocator, runtime_config: ?*const config_mod.RuntimeConfig) !?[]u8 {
    const config = runtime_config orelse return null;
    for (config.errors) |err| {
        if (err.source == .models or err.source == .register_model or err.source == .register_provider or err.source == .discovery) {
            return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ config_mod.configErrorSourceName(err.source), err.message });
        }
    }
    return null;
}

fn setEnabledIds(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay, next_ids: ?[][]u8) !void {
    if (overlay.enabled_ids) |ids| freeOwnedStrings(allocator, ids);
    overlay.enabled_ids = next_ids;
    overlay.dirty = true;
    try refreshScoped(allocator, overlay);
}

fn appendOrderedModelIndexes(allocator: std.mem.Allocator, ordered: *std.ArrayList(usize), overlay: *const ScopedModelsOverlay) !void {
    if (overlay.enabled_ids) |enabled_ids| {
        for (enabled_ids) |id| {
            if (modelIndexByFullId(overlay.all_models, id)) |index| try ordered.append(allocator, index);
        }
        for (overlay.all_models, 0..) |model, index| {
            const full_id = try formatModelFullId(allocator, model);
            defer allocator.free(full_id);
            if (indexOfString(enabled_ids, full_id) == null) try ordered.append(allocator, index);
        }
    } else {
        for (overlay.all_models, 0..) |_, index| try ordered.append(allocator, index);
    }
}

fn buildAllModelIds(allocator: std.mem.Allocator, models: []const provider_config.AvailableModel) ![][]u8 {
    const ids = try allocator.alloc([]u8, models.len);
    var initialized: usize = 0;
    errdefer {
        for (ids[0..initialized]) |id| allocator.free(id);
        allocator.free(ids);
    }
    for (models, 0..) |model, index| {
        ids[index] = try formatModelFullId(allocator, model);
        initialized += 1;
    }
    return ids;
}

fn cloneEnabledModelIds(allocator: std.mem.Allocator, patterns: []const []const u8) !?[][]u8 {
    if (patterns.len == 0) return null;
    const ids = try allocator.alloc([]u8, patterns.len);
    var initialized: usize = 0;
    errdefer {
        for (ids[0..initialized]) |id| allocator.free(id);
        allocator.free(ids);
    }
    for (patterns, 0..) |pattern, index| {
        ids[index] = try allocator.dupe(u8, pattern);
        initialized += 1;
    }
    return ids;
}

fn formatModelFullId(allocator: std.mem.Allocator, model: provider_config.AvailableModel) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ model.provider, model.model_id });
}

fn modelIndexByFullId(models: []const provider_config.AvailableModel, full_id: []const u8) ?usize {
    for (models, 0..) |model, index| {
        var buffer: [512]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ model.provider, model.model_id }) catch continue;
        if (std.mem.eql(u8, candidate, full_id)) return index;
    }
    return null;
}

fn scopedModelIsEnabled(enabled_ids: ?[][]u8, id: []const u8) bool {
    const ids = enabled_ids orelse return true;
    return indexOfString(ids, id) != null;
}

fn selectedScopedChoice(overlay: *const ScopedModelsOverlay) ?ScopedModelChoice {
    if (overlay.choices.len == 0) return null;
    const index = overlay.list.selectedIndex();
    if (index >= overlay.choices.len) return null;
    const choice = overlay.choices[index];
    if (choice.full_id.len == 0) return null;
    return choice;
}

pub fn indexOfString(items: []const []const u8, needle: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item, needle)) return index;
    }
    return null;
}

fn toggledEnabledIds(allocator: std.mem.Allocator, enabled_ids: ?[][]u8, id: []const u8) !?[][]u8 {
    if (enabled_ids) |ids| {
        if (indexOfString(ids, id)) |remove_index| {
            const result = try allocator.alloc([]u8, ids.len - 1);
            var out: usize = 0;
            errdefer {
                for (result[0..out]) |item| allocator.free(item);
                allocator.free(result);
            }
            for (ids, 0..) |item, index| {
                if (index == remove_index) continue;
                result[out] = try allocator.dupe(u8, item);
                out += 1;
            }
            return result;
        }
        const result = try allocator.alloc([]u8, ids.len + 1);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |item| allocator.free(item);
            allocator.free(result);
        }
        for (ids, 0..) |item, index| {
            result[index] = try allocator.dupe(u8, item);
            initialized += 1;
        }
        result[ids.len] = try allocator.dupe(u8, id);
        return result;
    }
    const result = try allocator.alloc([]u8, 1);
    errdefer allocator.free(result);
    result[0] = try allocator.dupe(u8, id);
    return result;
}

fn enabledAllIds(allocator: std.mem.Allocator, enabled_ids: ?[][]u8, all_ids: []const []const u8, target_ids: []const []const u8) !?[][]u8 {
    const source = enabled_ids orelse all_ids;
    var result = std.ArrayList([]u8).empty;
    errdefer freeOwnedStrings(allocator, result.items);
    for (source) |id| try appendUniqueOwned(allocator, &result, id);
    for (target_ids) |id| try appendUniqueOwned(allocator, &result, id);
    if (result.items.len == all_ids.len) {
        freeOwnedStrings(allocator, result.items);
        return null;
    }
    return try result.toOwnedSlice(allocator);
}

fn clearedAllIds(
    allocator: std.mem.Allocator,
    enabled_ids: ?[][]u8,
    all_ids: []const []const u8,
    target_ids: []const []const u8,
    filtered: bool,
) !?[][]u8 {
    var result = std.ArrayList([]u8).empty;
    errdefer freeOwnedStrings(allocator, result.items);
    if (enabled_ids) |ids| {
        for (ids) |id| {
            if (indexOfString(target_ids, id) == null) try appendUniqueOwned(allocator, &result, id);
        }
    } else {
        if (!filtered and target_ids.len == all_ids.len) return try result.toOwnedSlice(allocator);
        for (all_ids) |id| {
            if (indexOfString(target_ids, id) == null) try appendUniqueOwned(allocator, &result, id);
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn currentScopedTargetIds(allocator: std.mem.Allocator, overlay: *const ScopedModelsOverlay) ![][]u8 {
    if (overlay.search.len == 0) {
        const cloned = try allocator.alloc([]u8, overlay.all_ids.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |id| allocator.free(id);
            allocator.free(cloned);
        }
        for (overlay.all_ids, 0..) |id, index| {
            cloned[index] = try allocator.dupe(u8, id);
            initialized += 1;
        }
        return cloned;
    }

    var ids = std.ArrayList([]u8).empty;
    errdefer freeOwnedStrings(allocator, ids.items);
    for (overlay.choices) |choice| {
        if (choice.full_id.len > 0) try ids.append(allocator, try allocator.dupe(u8, choice.full_id));
    }
    return try ids.toOwnedSlice(allocator);
}

fn appendUniqueOwned(allocator: std.mem.Allocator, result: *std.ArrayList([]u8), id: []const u8) !void {
    if (indexOfString(result.items, id) != null) return;
    try result.append(allocator, try allocator.dupe(u8, id));
}

fn formatScopedModelsHint(allocator: std.mem.Allocator, overlay: *const ScopedModelsOverlay) ![]u8 {
    const enabled_count = if (overlay.enabled_ids) |ids| ids.len else overlay.all_ids.len;
    const count_text = if (overlay.enabled_ids == null)
        "all enabled"
    else
        try std.fmt.allocPrint(allocator, "{d}/{d} enabled", .{ enabled_count, overlay.all_ids.len });
    defer if (overlay.enabled_ids != null) allocator.free(count_text);
    return std.fmt.allocPrint(
        allocator,
        "Search: {s} • Enter toggle • Ctrl+A all • Ctrl+X clear • Ctrl+P provider • Alt+Up/Alt+Down reorder • Ctrl+S save • {s}{s}",
        .{ if (overlay.search.len > 0) overlay.search else "", count_text, if (overlay.dirty) " (unsaved)" else "" },
    );
}

fn freeModelChoices(allocator: std.mem.Allocator, choices: []ModelChoice) void {
    for (choices) |choice| {
        allocator.free(choice.provider);
        allocator.free(choice.model_id);
    }
    allocator.free(choices);
}

fn freeScopedModelChoices(allocator: std.mem.Allocator, choices: []ScopedModelChoice) void {
    for (choices) |choice| {
        allocator.free(choice.full_id);
        allocator.free(choice.provider);
        allocator.free(choice.model_id);
    }
    allocator.free(choices);
}

const freeOwnedSelectItems = overlay_table.freeOwnedSelectItems;

const freeOwnedStrings = overlay_table.freeOwnedStrings;

fn formatModelOverlayLabel(
    allocator: std.mem.Allocator,
    entry: provider_config.AvailableModel,
    provider_changed: bool,
) ![]u8 {
    if (provider_changed) {
        return std.fmt.allocPrint(
            allocator,
            "{s} / {s}",
            .{ provider_config.providerDisplayName(entry.provider), entry.display_name },
        );
    }
    return std.fmt.allocPrint(allocator, "  {s}", .{entry.display_name});
}

fn formatModelOverlayLabelWithCurrent(
    allocator: std.mem.Allocator,
    entry: provider_config.AvailableModel,
    provider_changed: bool,
    current_provider: []const u8,
    current_model_id: []const u8,
) ![]u8 {
    const base = try formatModelOverlayLabel(allocator, entry, provider_changed);
    defer allocator.free(base);
    const marker = if (std.mem.eql(u8, entry.provider, current_provider) and std.mem.eql(u8, entry.model_id, current_model_id)) " ✓" else "";
    return std.fmt.allocPrint(allocator, "{s} [{s}]{s}", .{ base, entry.provider, marker });
}

fn formatModelOverlayDescription(
    allocator: std.mem.Allocator,
    entry: provider_config.AvailableModel,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} • {s}",
        .{ entry.model_id, provider_config.providerAuthStatusLabel(entry.auth_status) },
    );
}
