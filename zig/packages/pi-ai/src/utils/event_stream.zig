pub const event_stream = @import("../event_stream.zig");
pub const AssistantMessageEventStream = event_stream.AssistantMessageEventStream;

test {
    _ = @import("../event_stream.zig");
}
