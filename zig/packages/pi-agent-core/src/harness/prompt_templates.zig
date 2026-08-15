pub const PromptTemplate = struct {
    name: []const u8,
    content: []const u8,
};

pub fn matchesTemplateName(template: PromptTemplate, name: []const u8) bool {
    const std = @import("std");
    return std.mem.eql(u8, template.name, name);
}
