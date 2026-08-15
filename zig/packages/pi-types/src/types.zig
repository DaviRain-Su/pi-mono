const std = @import("std");
const builtin = @import("builtin");
const json = @import("json.zig");

/// Canonical ordering for caller abort-signal classification across AI
/// stream entry points, provider setup paths, and HTTP streaming setup.
pub const abort_signal_load_order = .seq_cst;

pub const Api = []const u8;
pub const Provider = []const u8;
pub const ImagesApi = []const u8;
pub const ImagesProvider = []const u8;

pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ModelThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ThinkingLevelMapping = union(enum) {
    unsupported,
    mapped: []const u8,
};

pub const ModelThinkingLevelMap = struct {
    off: ?ThinkingLevelMapping = null,
    minimal: ?ThinkingLevelMapping = null,
    low: ?ThinkingLevelMapping = null,
    medium: ?ThinkingLevelMapping = null,
    high: ?ThinkingLevelMapping = null,
    xhigh: ?ThinkingLevelMapping = null,

    pub fn get(self: ModelThinkingLevelMap, level: ModelThinkingLevel) ?ThinkingLevelMapping {
        return switch (level) {
            .off => self.off,
            .minimal => self.minimal,
            .low => self.low,
            .medium => self.medium,
            .high => self.high,
            .xhigh => self.xhigh,
        };
    }
};

pub const AnthropicEffort = enum {
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const AnthropicThinkingDisplay = enum {
    summarized,
    omitted,
};

pub const ThinkingBudgets = struct {
    minimal: u32 = 1024,
    low: u32 = 2048,
    medium: u32 = 8192,
    high: u32 = 16384,
};

pub const AnthropicToolChoice = union(enum) {
    auto,
    any,
    none,
    tool: []const u8,
};

pub const BedrockToolChoice = union(enum) {
    auto,
    any,
    none,
    tool: []const u8,
};

pub const CacheRetention = enum {
    unset,
    none,
    short,
    long,
};

pub const Transport = enum {
    sse,
    websocket,
    websocket_cached,
    auto,
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    error_reason,
    aborted,
};

pub const UsageCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
    total: f64 = 0,

    pub fn init() UsageCost {
        return .{};
    }
};

pub const Usage = struct {
    input: u32 = 0,
    output: u32 = 0,
    cache_read: u32 = 0,
    cache_write: u32 = 0,
    /// Subset of `cache_write` written with 1h retention. Only Anthropic reports this split.
    cache_write_1h: u32 = 0,
    total_tokens: u32 = 0,
    cost: UsageCost = .{},

    pub fn init() Usage {
        return .{};
    }
};

pub const TextContent = struct {
    text: []const u8,
    text_signature: ?[]const u8 = null,
};

pub const ImageContent = struct {
    data: []const u8, // base64
    mime_type: []const u8,
};

pub const ImagesInputContent = union(enum) {
    text: TextContent,
    image: ImageContent,
};

pub const ImagesOutputContent = union(enum) {
    text: TextContent,
    image: ImageContent,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    /// Legacy field name kept for stored-session/provider compatibility during
    /// the ordered assistant content migration. Prefer `thinking_signature` for
    /// new code.
    signature: ?[]const u8 = null,
    redacted: bool = false,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    /// Optional encrypted/provider-private reasoning associated with this
    /// executable tool call. Providers that set this field must allocate it
    /// with the message allocator; `freeToolCall` and clone/deinit helpers own
    /// freeing it. Same-model replay/conversion may preserve it, while
    /// cross-model provider-context conversion must drop it because signatures
    /// are not portable across providers or model families.
    thought_signature: ?[]const u8 = null,
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    thinking: ThinkingContent,
    tool_call: ToolCall,
};

pub fn textSignature(text: TextContent) ?[]const u8 {
    return text.text_signature;
}

pub fn thinkingSignature(thinking: ThinkingContent) ?[]const u8 {
    return thinking.thinking_signature orelse thinking.signature;
}

pub const UserMessage = struct {
    role: []const u8 = "user",
    content: []const ContentBlock,
    timestamp: i64,
};

pub const AssistantMessage = struct {
    role: []const u8 = "assistant",
    content: []const ContentBlock,
    /// ISS-500 / INV-1: inline `.tool_call` blocks in `content` are canonical.
    /// Normalized providers must leave this legacy cache null; `openai_chat_sse`
    /// may populate it with separately owned compatibility copies.
    tool_calls: ?[]const ToolCall = null,
    api: Api,
    provider: Provider,
    model: []const u8,
    response_id: ?[]const u8 = null,
    /// Concrete `chunk.model` when different from the requested `model`
    /// (e.g. OpenRouter `auto` -> `anthropic/...`). Equivalent to
    /// TypeScript `AssistantMessage.responseModel`.
    response_model: ?[]const u8 = null,
    diagnostics: ?[]const AssistantMessageDiagnostic = null,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: i64,
};

pub fn countInlineToolCalls(assistant: AssistantMessage) usize {
    var count: usize = 0;
    for (assistant.content) |block| {
        if (block == .tool_call) count += 1;
    }
    return count;
}

pub fn hasInlineToolCalls(assistant: AssistantMessage) bool {
    return countInlineToolCalls(assistant) > 0;
}

pub fn shouldReplayAssistantInProviderContext(assistant: AssistantMessage) bool {
    return assistant.stop_reason != .error_reason and assistant.stop_reason != .aborted;
}

/// Collects executable tool calls with inline ordered content as source of
/// truth. The returned slice is an owned array of borrowed ToolCall values; free
/// only the slice, not the tool-call fields.
pub fn collectAssistantToolCalls(
    allocator: std.mem.Allocator,
    assistant: AssistantMessage,
) ![]const ToolCall {
    const inline_count = countInlineToolCalls(assistant);
    if (inline_count > 0) {
        var calls = try allocator.alloc(ToolCall, inline_count);
        var index: usize = 0;
        for (assistant.content) |block| {
            if (block == .tool_call) {
                calls[index] = block.tool_call;
                index += 1;
            }
        }
        return calls;
    }

    const legacy = assistant.tool_calls orelse return try allocator.alloc(ToolCall, 0);
    const calls = try allocator.alloc(ToolCall, legacy.len);
    @memcpy(calls, legacy);
    return calls;
}

/// Frees owned assistant-message payload fields from provider stream results.
/// `api`, `provider`, and `model` are borrowed model metadata.
pub fn freeAssistantMessage(allocator: std.mem.Allocator, message: AssistantMessage) void {
    assertNoInvalidDualOwnedToolCalls(message);
    freeContentBlocks(allocator, message.content);
    if (message.tool_calls) |tool_calls| freeToolCalls(allocator, tool_calls);
    if (message.response_id) |response_id| allocator.free(response_id);
    if (message.response_model) |response_model| allocator.free(response_model);
    if (message.diagnostics) |diagnostics| freeAssistantMessageDiagnostics(allocator, diagnostics);
    if (message.error_message) |error_message| allocator.free(error_message);
}

pub const DiagnosticErrorInfo = struct {
    name: ?[]const u8 = null,
    message: []const u8,
    stack: ?[]const u8 = null,
    code: ?std.json.Value = null,
};

pub const AssistantMessageDiagnostic = struct {
    type: []const u8,
    timestamp: i64,
    error_info: ?DiagnosticErrorInfo = null,
    details: ?std.json.Value = null,
};

pub fn freeAssistantMessageDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: []const AssistantMessageDiagnostic,
) void {
    for (diagnostics) |diagnostic| {
        allocator.free(diagnostic.type);
        if (diagnostic.error_info) |info| {
            if (info.name) |name| allocator.free(name);
            allocator.free(info.message);
            if (info.stack) |stack| allocator.free(stack);
            if (info.code) |code| json.freeValue(allocator, code);
        }
        if (diagnostic.details) |details| json.freeValue(allocator, details);
    }
    allocator.free(diagnostics);
}

fn assertNoInvalidDualOwnedToolCalls(message: AssistantMessage) void {
    if (builtin.mode != .Debug) return;
    const legacy_tool_calls = message.tool_calls orelse return;

    for (message.content) |block| {
        if (block != .tool_call) continue;
        for (legacy_tool_calls) |legacy_tool_call| {
            if (!toolCallStorageAliases(block.tool_call, legacy_tool_call)) continue;
            std.log.warn(
                "ISS-501 / INV-1: AssistantMessage has aliased inline and legacy tool_calls; normalized providers must keep tool_calls null",
                .{},
            );
            std.debug.assert(false);
        }
    }
}

fn toolCallStorageAliases(a: ToolCall, b: ToolCall) bool {
    if (a.id.ptr == b.id.ptr or a.name.ptr == b.name.ptr) return true;
    if (a.thought_signature != null and b.thought_signature != null and
        a.thought_signature.?.ptr == b.thought_signature.?.ptr)
    {
        return true;
    }
    return jsonValueStorageAliases(a.arguments, b.arguments);
}

fn jsonValueStorageAliases(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .string => |a_string| b == .string and a_string.ptr == b.string.ptr,
        .number_string => |a_number| b == .number_string and a_number.ptr == b.number_string.ptr,
        .array => |a_array| b == .array and a_array.items.ptr == b.array.items.ptr,
        .object => |a_object| b == .object and a_object.count() > 0 and a_object.count() == b.object.count() and
            jsonObjectMayShareStorage(a_object, b.object),
        else => false,
    };
}

fn jsonObjectMayShareStorage(a: std.json.ObjectMap, b: std.json.ObjectMap) bool {
    var iterator = a.iterator();
    while (iterator.next()) |entry| {
        if (b.getEntry(entry.key_ptr.*)) |other| {
            if (entry.key_ptr.*.ptr == other.key_ptr.*.ptr) return true;
            if (jsonValueStorageAliases(entry.value_ptr.*, other.value_ptr.*)) return true;
        }
    }
    return false;
}

pub fn freeContentBlocks(allocator: std.mem.Allocator, blocks: []const ContentBlock) void {
    for (blocks) |block| freeContentBlock(allocator, block);
    allocator.free(blocks);
}

pub fn freeContentBlock(allocator: std.mem.Allocator, block: ContentBlock) void {
    switch (block) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |signature| allocator.free(signature);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |signature| allocator.free(signature);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |tool_call| freeToolCall(allocator, tool_call),
    }
}

pub fn freeToolCalls(allocator: std.mem.Allocator, tool_calls: []const ToolCall) void {
    for (tool_calls) |tool_call| freeToolCall(allocator, tool_call);
    allocator.free(tool_calls);
}

pub fn freeToolCall(allocator: std.mem.Allocator, tool_call: ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    json.freeValue(allocator, tool_call.arguments);
}

pub const ToolResultMessage = struct {
    role: []const u8 = "toolResult",
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ContentBlock,
    details: ?std.json.Value = null,
    is_error: bool = false,
    timestamp: i64,
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};

pub const ModelCost = struct {
    input: f64 = 0, // $/million tokens
    output: f64 = 0, // $/million tokens
    cache_read: f64 = 0, // $/million tokens
    cache_write: f64 = 0, // $/million tokens

    pub fn init() ModelCost {
        return .{};
    }
};

pub const OpenAICompletionsCompat = struct {
    supports_store: ?bool = null,
    supports_developer_role: ?bool = null,
    supports_reasoning_effort: ?bool = null,
    reasoning_effort_map: ?std.StringHashMap([]const u8) = null,
    supports_usage_in_streaming: bool = true,
    max_tokens_field: ?[]const u8 = null, // "max_completion_tokens" or "max_tokens"
    requires_tool_result_name: ?bool = null,
    requires_assistant_after_tool_result: ?bool = null,
    requires_thinking_as_text: ?bool = null,
    requires_reasoning_content_on_assistant_messages: ?bool = null,
    thinking_format: ?[]const u8 = null, // "openai", "openrouter", "deepseek", "zai", "qwen", "qwen-chat-template"
    open_router_routing: ?OpenRouterRouting = null,
    vercel_gateway_routing: ?VercelGatewayRouting = null,
    zai_tool_stream: bool = false,
    supports_strict_mode: bool = true,
    cache_control_format: ?[]const u8 = null, // "anthropic"
    send_session_affinity_headers: bool = false,
    supports_long_cache_retention: ?bool = null,
};

pub const OpenAIResponsesCompat = struct {
    send_session_id_header: ?bool = null,
    supports_long_cache_retention: ?bool = null,
};

pub const AnthropicMessagesCompat = struct {
    supports_eager_tool_input_streaming: ?bool = null,
    supports_long_cache_retention: ?bool = null,
    send_session_affinity_headers: ?bool = null,
    supports_cache_control_on_tools: ?bool = null,
};

pub const OpenRouterRouting = struct {
    allow_fallbacks: ?bool = null,
    require_parameters: ?bool = null,
    data_collection: ?[]const u8 = null, // "deny" or "allow"
    zdr: ?bool = null,
    enforce_distillable_text: ?bool = null,
    order: ?[]const []const u8 = null,
    only: ?[]const []const u8 = null,
    ignore: ?[]const []const u8 = null,
    quantizations: ?[]const []const u8 = null,
    sort: ?[]const u8 = null,
    max_price: ?std.json.Value = null,
    preferred_min_throughput: ?std.json.Value = null,
    preferred_max_latency: ?std.json.Value = null,
};

pub const VercelGatewayRouting = struct {
    only: ?[]const []const u8 = null,
    order: ?[]const []const u8 = null,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: Provider,
    base_url: []const u8,
    reasoning: bool = false,
    thinking_level_map: ?ModelThinkingLevelMap = null,
    tool_calling: bool = true,
    loaded: bool = false,
    input_types: []const []const u8, // "text", "image"
    cost: ModelCost = .{},
    context_window: u32,
    max_tokens: u32,
    headers: ?std.StringHashMap([]const u8) = null,
    compat: ?std.json.Value = null, // OpenAICompletionsCompat or OpenAIResponsesCompat
};

pub const GoogleThinkingOptions = struct {
    enabled: bool = false,
    budget_tokens: ?u32 = null,
    level: ?[]const u8 = null,
};

// Provider-specific streaming options extracted from StreamOptions.
// Each provider's stream() function accesses its variant via
// `options.provider` (a ProviderStreamOptions union).
pub const AnthropicStreamOptions = struct {
    thinking_enabled: ?bool = null,
    thinking_budget_tokens: ?u32 = null,
    thinking_display: ?AnthropicThinkingDisplay = null,
    effort: ?AnthropicEffort = null,
    interleaved_thinking: ?bool = null,
    tool_choice: ?AnthropicToolChoice = null,
};

pub const BedrockStreamOptions = struct {
    region: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    bearer_token: ?[]const u8 = null,
    tool_choice: ?BedrockToolChoice = null,
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,
    interleaved_thinking: ?bool = null,
    thinking_display: ?AnthropicThinkingDisplay = null,
    request_metadata: ?std.json.Value = null,
};

pub const AzureStreamOptions = struct {
    api_version: ?[]const u8 = null,
    resource_name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    deployment_name: ?[]const u8 = null,
};

pub const GoogleStreamOptions = struct {
    tool_choice: ?[]const u8 = null,
    thinking: ?GoogleThinkingOptions = null,
};

pub const MistralStreamOptions = struct {
    prompt_mode: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
};

pub const OpenAIChatStreamOptions = struct {
    tool_choice: ?std.json.Value = null,
    reasoning_effort: ?[]const u8 = null,
};

pub const ResponsesStreamOptions = struct {
    reasoning_effort: ?ThinkingLevel = null,
    reasoning_summary: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    text_verbosity: ?[]const u8 = null,
};

/// Provider-specific stream options, composable across providers.
///
/// Modeled as a struct of optionals (not a tagged union) because real requests
/// can require multiple providers' configuration at once — e.g. Azure-OpenAI-
/// Responses needs both `azure` (endpoint/deployment) and `responses`
/// (reasoning/verbosity) configuration in the same request. Setting `null`
/// means "no provider-specific override at this layer".
pub const ProviderStreamOptions = struct {
    anthropic: ?AnthropicStreamOptions = null,
    azure: ?AzureStreamOptions = null,
    bedrock: ?BedrockStreamOptions = null,
    google: ?GoogleStreamOptions = null,
    mistral: ?MistralStreamOptions = null,
    openai: ?OpenAIChatStreamOptions = null,
    responses: ?ResponsesStreamOptions = null,
};

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .unset,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    /// Optional callback for inspecting or replacing provider payloads before sending.
    /// HTTP request timeout in milliseconds for providers/clients that support it.
    timeout_ms: ?u32 = null,
    /// Maximum retry attempts for providers/clients that support client-side retries.
    max_retries: ?u32 = null,
    /// In Zig, this is a function pointer taking allocator, payload json.Value, model, and returning an optional modified payload.
    on_payload: ?*const fn (std.mem.Allocator, std.json.Value, Model) anyerror!?std.json.Value = null,
    /// Optional callback invoked after an HTTP response is received and before its body stream is consumed.
    on_response: ?*const fn (u16, std.StringHashMap([]const u8), Model) anyerror!void = null,
    /// Optional abort signal checked during streaming.
    signal: ?*const std.atomic.Value(bool) = null,
    /// Maximum delay in milliseconds to wait for a retry when the server requests a long wait.
    /// Default: 60000 (60 seconds). Set to 0 to disable the cap.
    max_retry_delay_ms: u32 = 60000,
    /// Optional metadata to include in API requests.
    metadata: ?std.json.Value = null,

    /// WebSocket connect timeout in milliseconds (for providers that use WebSocket).
    websocket_connect_timeout_ms: ?u32 = null,

    /// Provider-scoped environment overrides. Values take precedence over process env.
    /// In Zig, this is an optional string-to-string map. The caller owns the map.
    env: ?std.StringHashMap([]const u8) = null,

    /// Provider-specific options, composable across providers (see
    /// `ProviderStreamOptions`).
    provider: ProviderStreamOptions = .{},

    /// Returns the provider-specific options for `field_name` (a field name on
    /// `ProviderStreamOptions`), falling back to the variant's default if the
    /// caller did not set them. The seven per-provider accessors collapse into
    /// this single reflection-based helper.
    pub fn providerOptions(
        self: StreamOptions,
        comptime field_name: []const u8,
    ) @typeInfo(@FieldType(ProviderStreamOptions, field_name)).optional.child {
        return @field(self.provider, field_name) orelse .{};
    }
};

pub const SimpleStreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .unset,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
    timeout_ms: ?u32 = null,
    max_retries: ?u32 = null,
    on_payload: ?*const fn (std.mem.Allocator, std.json.Value, Model) anyerror!?std.json.Value = null,
    on_response: ?*const fn (u16, std.StringHashMap([]const u8), Model) anyerror!void = null,
    max_retry_delay_ms: u32 = 60000,
    metadata: ?std.json.Value = null,
    websocket_connect_timeout_ms: ?u32 = null,
    signal: ?*const std.atomic.Value(bool) = null,
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,

    /// Convert SimpleStreamOptions to StreamOptions.
    ///
    /// Same-named fields are copied via comptime field iteration so adding
    /// a field on either struct keeps the two in sync without manual edits.
    pub fn toStreamOptions(self: SimpleStreamOptions) StreamOptions {
        var opts: StreamOptions = .{};
        inline for (@typeInfo(SimpleStreamOptions).@"struct".fields) |field| {
            if (comptime @hasField(StreamOptions, field.name)) {
                @field(opts, field.name) = @field(self, field.name);
            }
        }
        // Generic `reasoning` + `thinking_budgets` fan out to provider-specific knobs.
        opts.provider.responses = .{ .reasoning_effort = self.reasoning };
        opts.provider.bedrock = .{
            .reasoning = self.reasoning,
            .thinking_budgets = self.thinking_budgets,
        };
        return opts;
    }
};

/// Event ordering follows ISS-502 / INV-2..INV-5; see event_stream.zig.
pub const EventType = enum {
    start,
    text_start,
    text_delta,
    text_end,
    thinking_start,
    thinking_delta,
    thinking_end,
    toolcall_start,
    toolcall_delta,
    toolcall_end,
    done,
    error_event,
};

pub const AssistantMessageEvent = struct {
    event_type: EventType,
    /// Stable block id for text/thinking/tool-call start, delta, and end events.
    content_index: ?u32 = null,
    delta: ?[]const u8 = null,
    owns_delta: bool = false,
    content: ?[]const u8 = null,
    tool_call: ?ToolCall = null,
    message: ?AssistantMessage = null,
    error_message: ?[]const u8 = null,

    pub fn deinitTransient(self: AssistantMessageEvent, allocator: std.mem.Allocator) void {
        if (self.owns_delta) {
            if (self.delta) |delta| allocator.free(delta);
        }
    }
};

pub const ImagesStopReason = enum {
    stop,
    @"error",
    aborted,
};

pub const ImagesContext = struct {
    input: []const ImagesInputContent,
};

pub const ImagesModel = struct {
    id: []const u8,
    name: []const u8,
    api: ImagesApi,
    provider: ImagesProvider,
    base_url: []const u8,
    input: []const []const u8,
    output: []const []const u8,
    cost: ModelCost = .{},
    headers: ?std.StringHashMap([]const u8) = null,
};

pub const AssistantImages = struct {
    api: ImagesApi,
    provider: ImagesProvider,
    model: []const u8,
    output: []const ImagesOutputContent,
    response_id: ?[]const u8 = null,
    usage: ?Usage = null,
    stop_reason: ImagesStopReason = .stop,
    error_message: ?[]const u8 = null,
    timestamp: i64,
};

pub const ImagesOptions = struct {
    api_key: ?[]const u8 = null,
    on_payload: ?*const fn (std.mem.Allocator, std.json.Value, ImagesModel) anyerror!?std.json.Value = null,
    on_response: ?*const fn (u16, std.StringHashMap([]const u8), ImagesModel) anyerror!void = null,
    headers: ?std.StringHashMap([]const u8) = null,
    timeout_ms: ?u32 = null,
    max_retries: ?u32 = null,
    max_retry_delay_ms: u32 = 60000,
    signal: ?*const std.atomic.Value(bool) = null,
    metadata: ?std.json.Value = null,
};

pub fn freeImagesContent(allocator: std.mem.Allocator, content: ImagesOutputContent) void {
    switch (content) {
        .text => |text| allocator.free(text.text),
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    }
}

pub fn freeAssistantImages(allocator: std.mem.Allocator, images: AssistantImages) void {
    if (images.usage != null) {}
    for (images.output) |content| freeImagesContent(allocator, content);
    allocator.free(images.output);
    if (images.response_id) |response_id| allocator.free(response_id);
    if (images.error_message) |error_message| allocator.free(error_message);
}

test "Usage defaults" {
    const usage = Usage.init();
    try std.testing.expectEqual(@as(u32, 0), usage.input);
    try std.testing.expectEqual(@as(u32, 0), usage.output);
    try std.testing.expectEqual(@as(u32, 0), usage.cache_read);
    try std.testing.expectEqual(@as(u32, 0), usage.cache_write);
    try std.testing.expectEqual(@as(u32, 0), usage.total_tokens);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.input);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.output);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.cache_read);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.cache_write);
    try std.testing.expectEqual(@as(f64, 0), usage.cost.total);
}

test "UsageCost construction" {
    const cost = UsageCost{ .input = 1.5, .output = 2.0, .cache_read = 0.75, .cache_write = 1.0, .total = 5.25 };
    try std.testing.expectEqual(@as(f64, 1.5), cost.input);
    try std.testing.expectEqual(@as(f64, 2.0), cost.output);
    try std.testing.expectEqual(@as(f64, 0.75), cost.cache_read);
    try std.testing.expectEqual(@as(f64, 1.0), cost.cache_write);
    try std.testing.expectEqual(@as(f64, 5.25), cost.total);
}

test "Message union" {
    const user_msg = Message{ .user = .{
        .content = &[1]ContentBlock{.{ .text = .{ .text = "hello" } }},
        .timestamp = 1234567890,
    } };
    try std.testing.expectEqualStrings("user", user_msg.user.role);
}

test "ContentBlock union variants" {
    const text_block = ContentBlock{ .text = .{ .text = "hello" } };
    try std.testing.expectEqualStrings("hello", text_block.text.text);

    const image_block = ContentBlock{ .image = .{ .data = "base64data", .mime_type = "image/png" } };
    try std.testing.expectEqualStrings("base64data", image_block.image.data);
    try std.testing.expectEqualStrings("image/png", image_block.image.mime_type);

    const thinking_block = ContentBlock{ .thinking = .{ .thinking = "thinking text", .signature = "sig", .redacted = true } };
    try std.testing.expectEqualStrings("thinking text", thinking_block.thinking.thinking);
    try std.testing.expectEqualStrings("sig", thinking_block.thinking.signature.?);
    try std.testing.expect(thinking_block.thinking.redacted);
}

test "AssistantMessage with responseId" {
    const msg = AssistantMessage{
        .content = &[_]ContentBlock{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };
    try std.testing.expectEqualStrings("assistant", msg.role);
}

fn makeOwnedToolCallForTest(
    allocator: std.mem.Allocator,
    id_value: []const u8,
    name_value: []const u8,
    city_value: []const u8,
) !ToolCall {
    const id = try allocator.dupe(u8, id_value);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, name_value);
    errdefer allocator.free(name);

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer json.freeValue(allocator, .{ .object = object });
    const key = try allocator.dupe(u8, "city");
    errdefer allocator.free(key);
    const city = try allocator.dupe(u8, city_value);
    errdefer allocator.free(city);
    try object.put(allocator, key, .{ .string = city });

    return .{
        .id = id,
        .name = name,
        .arguments = .{ .object = object },
    };
}

test "freeAssistantMessage releases normalized inline tool calls" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(ContentBlock, 1);
    content[0] = .{ .tool_call = try makeOwnedToolCallForTest(allocator, "call_1", "get_weather", "Berlin") };

    freeAssistantMessage(allocator, .{
        .content = content,
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    });
}

test "freeAssistantMessage preserves openai_chat_sse legacy dual copies" {
    const allocator = std.testing.allocator;

    const content = try allocator.alloc(ContentBlock, 1);
    content[0] = .{ .tool_call = try makeOwnedToolCallForTest(allocator, "call_1", "get_weather", "Berlin") };

    const legacy_tool_calls = try allocator.alloc(ToolCall, 1);
    legacy_tool_calls[0] = try makeOwnedToolCallForTest(allocator, "call_1", "get_weather", "Paris");

    freeAssistantMessage(allocator, .{
        .content = content,
        .tool_calls = legacy_tool_calls,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 2,
    });
}

test "OpenAICompletionsCompat parity fields" {
    const compat = OpenAICompletionsCompat{
        .requires_reasoning_content_on_assistant_messages = true,
        .open_router_routing = .{
            .allow_fallbacks = false,
        },
        .vercel_gateway_routing = .{
            .only = &[_][]const u8{"openai"},
        },
        .supports_long_cache_retention = false,
    };
    try std.testing.expectEqual(true, compat.requires_reasoning_content_on_assistant_messages.?);
    try std.testing.expectEqual(false, compat.open_router_routing.?.allow_fallbacks.?);
    try std.testing.expectEqual(@as(usize, 1), compat.vercel_gateway_routing.?.only.?.len);
    try std.testing.expectEqualStrings("openai", compat.vercel_gateway_routing.?.only.?[0]);
    try std.testing.expectEqual(false, compat.supports_long_cache_retention.?);
}

test "StreamOptions parity timeout and retries" {
    const options = StreamOptions{
        .timeout_ms = 30_000,
        .max_retries = 4,
    };
    try std.testing.expectEqual(@as(u32, 30_000), options.timeout_ms.?);
    try std.testing.expectEqual(@as(u32, 4), options.max_retries.?);
}

test "ImagesStopReason preserves error tag" {
    try std.testing.expectEqualStrings("error", @tagName(ImagesStopReason.@"error"));
}

test "Model with cost and compat" {
    const model = Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .cost = .{ .input = 30.0, .output = 60.0, .cache_read = 15.0, .cache_write = 30.0 },
        .context_window = 8192,
        .max_tokens = 4096,
        .compat = null,
    };
    try std.testing.expectEqualStrings("gpt-4", model.id);
    try std.testing.expect(model.reasoning);
    try std.testing.expectEqual(@as(f64, 30.0), model.cost.input);
    try std.testing.expectEqual(@as(f64, 60.0), model.cost.output);
    try std.testing.expectEqual(@as(f64, 15.0), model.cost.cache_read);
    try std.testing.expectEqual(@as(f64, 30.0), model.cost.cache_write);
    try std.testing.expectEqual(@as(usize, 2), model.input_types.len);
}

