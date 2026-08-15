const std = @import("std");
const ai = @import("ai");
const tui = @import("tui");

pub const PendingEditorImage = struct {
    data: []const u8,
    mime_type: []const u8,
    kitty_image: ?tui.components.image.KittyImage = null,

    pub fn content(self: PendingEditorImage) ai.ImageContent {
        return .{
            .data = self.data,
            .mime_type = self.mime_type,
        };
    }
};

pub const DeleteImageSink = struct {
    context: ?*anyopaque,
    callback: *const fn (context: ?*anyopaque, image_id: u32) void,

    pub fn delete(self: DeleteImageSink, image_id: u32) void {
        if (image_id == 0) return;
        self.callback(self.context, image_id);
    }
};

pub const Store = struct {
    pending_editor_images: std.ArrayList(PendingEditorImage) = .empty,
    retired_kitty_images: std.ArrayList(u32) = .empty,

    pub fn appendPendingContent(self: *Store, allocator: std.mem.Allocator, image: ai.ImageContent) !void {
        try self.pending_editor_images.append(allocator, .{
            .data = image.data,
            .mime_type = image.mime_type,
        });
    }

    pub fn appendPendingOwned(self: *Store, allocator: std.mem.Allocator, image: PendingEditorImage) !void {
        try self.pending_editor_images.append(allocator, image);
    }

    pub fn clearPending(self: *Store, allocator: std.mem.Allocator) void {
        for (self.pending_editor_images.items) |*image| {
            self.retirePendingImage(allocator, image);
            deinitImage(allocator, image);
        }
        self.pending_editor_images.clearRetainingCapacity();
    }

    pub fn cloneContents(self: *const Store, allocator: std.mem.Allocator) ![]ai.ImageContent {
        if (self.pending_editor_images.items.len == 0) return &.{};
        const cloned = try allocator.alloc(ai.ImageContent, self.pending_editor_images.items.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            }
            allocator.free(cloned);
        }
        for (self.pending_editor_images.items, 0..) |image, index| {
            cloned[index] = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            };
            initialized += 1;
        }
        return cloned;
    }

    pub fn retirePendingImage(self: *Store, allocator: std.mem.Allocator, image: *PendingEditorImage) void {
        if (image.kitty_image) |kitty| {
            self.retired_kitty_images.append(allocator, kitty.id) catch {};
            image.kitty_image = null;
        }
    }

    pub fn flushRetired(self: *Store, sink: DeleteImageSink) void {
        for (self.retired_kitty_images.items) |image_id| sink.delete(image_id);
        self.retired_kitty_images.clearRetainingCapacity();
    }

    pub fn freeActive(self: *Store, allocator: std.mem.Allocator, sink: DeleteImageSink) void {
        for (self.pending_editor_images.items) |*image| {
            if (image.kitty_image) |kitty| sink.delete(kitty.id);
            deinitImage(allocator, image);
        }
        self.pending_editor_images.clearRetainingCapacity();
        self.flushRetired(sink);
    }

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.pending_editor_images.items) |*image| deinitImage(allocator, image);
        self.pending_editor_images.deinit(allocator);
        self.retired_kitty_images.deinit(allocator);
        self.* = undefined;
    }
};

pub fn deinit(allocator: std.mem.Allocator, image: *PendingEditorImage) void {
    deinitImage(allocator, image);
}

fn deinitImage(allocator: std.mem.Allocator, image: *PendingEditorImage) void {
    allocator.free(image.data);
    allocator.free(image.mime_type);
    image.* = undefined;
}

pub fn cloneForRender(allocator: std.mem.Allocator, images: []const PendingEditorImage) ![]PendingEditorImage {
    if (images.len == 0) return &.{};

    const cloned = try allocator.alloc(PendingEditorImage, images.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*image| deinitImage(allocator, image);
        allocator.free(cloned);
    }

    for (images, 0..) |image, index| {
        cloned[index] = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
            .kitty_image = image.kitty_image,
        };
        initialized += 1;
    }
    return cloned;
}

pub fn deinitForRender(allocator: std.mem.Allocator, images: []PendingEditorImage) void {
    for (images) |*image| deinitImage(allocator, image);
    if (images.len > 0) allocator.free(images);
}

test "store clones and retires pending images" {
    const allocator = std.testing.allocator;
    var store = Store{};
    defer store.deinit(allocator);

    try store.appendPendingOwned(allocator, .{
        .data = try allocator.dupe(u8, "AQID"),
        .mime_type = try allocator.dupe(u8, "image/png"),
        .kitty_image = .{ .id = 7, .width_px = 16, .height_px = 8 },
    });

    const cloned = try store.cloneContents(allocator);
    defer {
        for (cloned) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        if (cloned.len > 0) allocator.free(cloned);
    }
    try std.testing.expectEqual(@as(usize, 1), cloned.len);
    try std.testing.expectEqualStrings("image/png", cloned[0].mime_type);

    const Sink = struct {
        fn delete(context: ?*anyopaque, image_id: u32) void {
            const list: *std.ArrayList(u32) = @ptrCast(@alignCast(context.?));
            list.append(std.testing.allocator, image_id) catch unreachable;
        }
    };
    var deleted = std.ArrayList(u32).empty;
    defer deleted.deinit(allocator);

    store.retirePendingImage(allocator, &store.pending_editor_images.items[0]);
    store.flushRetired(.{ .context = &deleted, .callback = Sink.delete });
    try std.testing.expectEqual(@as(usize, 1), deleted.items.len);
    try std.testing.expectEqual(@as(u32, 7), deleted.items[0]);
}
