const std = @import("std");
const ai = @import("ai");
const session_mod = @import("../sessions/session.zig");
const rendering = @import("rendering.zig");
const AppState = rendering.AppState;

pub const PromptWorker = struct {
    session: *session_mod.AgentSession,
    app_state: *AppState,
    prompt_text: []u8 = &.{},
    prompt_images: []ai.ImageContent = &.{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(
        self: *PromptWorker,
        allocator: std.mem.Allocator,
        session: *session_mod.AgentSession,
        app_state: *AppState,
        prompt_text: []const u8,
        prompt_images: []const ai.ImageContent,
    ) !void {
        self.session = session;
        self.app_state = app_state;
        self.prompt_text = try allocator.dupe(u8, prompt_text);
        errdefer {
            allocator.free(self.prompt_text);
            self.prompt_text = &.{};
        }
        self.prompt_images = try cloneImageContents(allocator, prompt_images);
        errdefer {
            deinitImageContents(allocator, self.prompt_images);
            self.prompt_images = &.{};
        }
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{ self, allocator });
    }

    pub fn join(self: *PromptWorker, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.prompt_text.len > 0) allocator.free(self.prompt_text);
        deinitImageContents(allocator, self.prompt_images);
        self.prompt_text = &.{};
        self.prompt_images = &.{};
        self.thread = null;
        self.running.store(false, .seq_cst);
    }

    pub fn run(self: *PromptWorker, allocator: std.mem.Allocator) void {
        defer self.running.store(false, .seq_cst);
        const result = if (self.prompt_images.len > 0)
            self.session.prompt(.{
                .text = self.prompt_text,
                .images = self.prompt_images,
            })
        else
            self.session.prompt(self.prompt_text);

        result catch |err| {
            const message = std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) catch return;
            defer allocator.free(message);
            self.app_state.appendError(message) catch {};
            return;
        };
    }
};

pub fn cloneImageContents(allocator: std.mem.Allocator, images: []const ai.ImageContent) ![]ai.ImageContent {
    if (images.len == 0) return &.{};

    const cloned = try allocator.alloc(ai.ImageContent, images.len);
    errdefer {
        for (cloned[0..images.len]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(cloned);
    }

    for (images, 0..) |image, index| {
        cloned[index] = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        };
    }
    return cloned;
}

pub fn deinitImageContents(allocator: std.mem.Allocator, images: []const ai.ImageContent) void {
    if (images.len == 0) return;
    for (images) |image| {
        allocator.free(image.data);
        allocator.free(image.mime_type);
    }
    allocator.free(images);
}
