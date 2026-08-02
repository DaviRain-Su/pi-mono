//! Memory-backed session storage handle lives with the backend compose.
//! Re-export for package layout parity with `session/storage/*`.
pub const InMemorySessionStorage = @import("../repo/memory.zig").InMemorySessionStorage;
pub const MemorySessionStorage = InMemorySessionStorage;
