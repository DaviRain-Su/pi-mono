pub const sanitize_unicode = @import("../shared/sanitize_unicode.zig");
pub const sanitizeSurrogates = sanitize_unicode.sanitizeSurrogates;

test {
    _ = @import("../shared/sanitize_unicode.zig");
}
