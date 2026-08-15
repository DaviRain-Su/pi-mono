pub const json_parse = @import("../json_parse.zig");
pub const parseStreamingJson = json_parse.parseStreamingJson;

test {
    _ = json_parse;
}
