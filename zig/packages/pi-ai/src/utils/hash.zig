pub const hash = @import("../shared/hash.zig");
pub const shortHash = hash.shortHash;

test {
    _ = @import("../shared/hash.zig");
}
