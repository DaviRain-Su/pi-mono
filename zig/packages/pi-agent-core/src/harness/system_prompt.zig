pub const DEFAULT_SYSTEM_PROMPT = "You are an AI coding assistant.";

pub fn buildSystemPrompt(extra: ?[]const u8) []const u8 {
    return extra orelse DEFAULT_SYSTEM_PROMPT;
}
