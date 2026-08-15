pub const headers = @import("../shared/headers.zig");
pub const headersToRecord = headers.headersToRecord;

test {
    _ = @import("../shared/headers.zig");
}
