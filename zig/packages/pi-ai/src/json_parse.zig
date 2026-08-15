const json_parse = @import("pi-types").json_parse;

pub const JSON_REPAIR_MAX_INPUT_BYTES = json_parse.JSON_REPAIR_MAX_INPUT_BYTES;
pub const JSON_REPAIR_MAX_WORK_UNITS = json_parse.JSON_REPAIR_MAX_WORK_UNITS;
pub const JSON_REPAIR_MAX_NESTING_DEPTH = json_parse.JSON_REPAIR_MAX_NESTING_DEPTH;
pub const parseJsonWithRepair = json_parse.parseJsonWithRepair;
pub const parseStreamingJson = json_parse.parseStreamingJson;
