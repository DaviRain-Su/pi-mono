pub const Skill = struct {
    name: []const u8,
    description: []const u8,
};

pub fn isVisibleToModel(disable_model_invocation: bool) bool {
    return !disable_model_invocation;
}
