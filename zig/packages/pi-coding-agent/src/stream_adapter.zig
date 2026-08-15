const std = @import("std");
const ai = @import("ai");
const pi_types = @import("pi-types");

/// Host-side StreamFn that closes over the model plane.
/// Agent-core sees only pi-types; coding-agent injects this adapter.
pub fn streamSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    context: pi_types.Context,
    options: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    return ai.streamSimple(allocator, io, model, context, options);
}
