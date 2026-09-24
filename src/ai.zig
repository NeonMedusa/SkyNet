const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const config_mod = @import("config.zig");
const Log = @import("log.zig");

pub const Affinity = config_mod.Affinity;
pub const CacheRetention = config_mod.CacheRetention;
pub const Behavior = config_mod.Behavior;

pub const OpenAIConfig = struct {
    api_key: []const u8,
    model: []const u8 = "gpt-3.5-turbo",
    endpoint: []const u8 = "https://api.openai.com/v1/chat/completions",
    /// 会话路由标识（按对话稳定，用于 prompt 缓存亲和）
    session_id: []const u8 = "",
    /// 提供商请求行为（方言 / 缓存参数 / 额外头）
    behavior: config_mod.Behavior = .{},
};

/// 自定义 User-Agent（文档要求客户端标识自己而非通用 HTTP 库）
pub const user_agent = "SkyNet/0.1";

/// 端点主机名是否为 opencode.ai（仅该网关需要 x-opencode-session 等头）
pub const isOpenCodeEndpoint = config_mod.isOpenCodeHost;

/// 一次请求的 token 用量（流式最后一个 chunk 里带回）
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cached_tokens: u64 = 0,
};

/// 会话路由标识最长 64 字符（OpenAI prompt_cache_key 限制）
fn clampSessionKey(buf: []u8, session_id: []const u8) []const u8 {
    if (session_id.len <= buf.len) return session_id;
    var end: usize = buf.len;
    while (end > 0 and (session_id[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(buf[0..end], session_id[0..end]);
    return buf[0..end];
}

pub const ToolCall = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    /// 原始 JSON 参数文本
    arguments: []const u8 = "",
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    /// 工具结果消息对应的调用 id（role = "tool"）
    tool_call_id: ?[]const u8 = null,
    /// 助手消息发起的工具调用
    tool_calls: ?[]const ToolCall = null,
    /// 落库行 id（0 = 未落库；仅本地使用，不参与请求序列化）
    db_id: i64 = 0,
    /// 已对 AI 折叠（仅本地使用；content 仍是全文，发请求前换 stub）
    folded: bool = false,
};

/// 工具定义（parameters 为 JSON Schema 文本）
pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

/// 用 std.json.Value 构建请求体（正确处理 tool_calls / tools / 可选字段）
pub fn buildRequestBody(
    allocator: Allocator,
    model: []const u8,
    messages: []const Message,
    tools: []const ToolSchema,
    session_id: []const u8,
    behavior: Behavior,
) error{OutOfMemory}![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root = std.json.ObjectMap{};
    try root.put(a, "model", .{ .string = model });
    // 不发送 temperature：使用服务端默认值（与 pi 一致；不同模型支持的取值范围不同）
    try root.put(a, "stream", .{ .bool = true });

    // 缓存亲和：prompt_cache_key / prompt_cache_retention / 流式 usage
    if (behavior.cache_key and session_id.len > 0) {
        var key_buf: [64]u8 = undefined;
        try root.put(a, "prompt_cache_key", .{ .string = try a.dupe(u8, clampSessionKey(&key_buf, session_id)) });
    }
    if (behavior.retention == .long) {
        try root.put(a, "prompt_cache_retention", .{ .string = "24h" });
    }
    if (behavior.include_usage) {
        var stream_options = std.json.ObjectMap{};
        try stream_options.put(a, "include_usage", .{ .bool = true });
        try root.put(a, "stream_options", .{ .object = stream_options });
    }

    // 思考强度：openai 兼容发 reasoning_effort；DeepSeek 直连另需 thinking 开关
    // （DeepSeek 有效档位 high/max，关闭用 thinking.type=disabled）
    if (behavior.reasoning_effort.len > 0) {
        if (std.mem.eql(u8, behavior.reasoning_effort, "off")) {
            if (behavior.deepseek_thinking) {
                var thinking = std.json.ObjectMap{};
                try thinking.put(a, "type", .{ .string = "disabled" });
                try root.put(a, "thinking", .{ .object = thinking });
            }
        } else {
            try root.put(a, "reasoning_effort", .{ .string = behavior.reasoning_effort });
            if (behavior.deepseek_thinking) {
                var thinking = std.json.ObjectMap{};
                try thinking.put(a, "type", .{ .string = "enabled" });
                try root.put(a, "thinking", .{ .object = thinking });
            }
        }
    }

    var msg_arr = std.json.Array.init(a);
    // 修复悬空工具调用（取消/中止导致结果缺失）后再序列化，避免服务端拒绝整个请求
    const repaired = try repairDanglingToolCalls(a, messages);
    for (repaired) |m| try msg_arr.append(try messageToValue(a, m));
    try root.put(a, "messages", .{ .array = msg_arr });

    if (tools.len > 0) {
        var tool_arr = std.json.Array.init(a);
        for (tools) |t| {
            var fn_obj = std.json.ObjectMap{};
            try fn_obj.put(a, "name", .{ .string = t.name });
            try fn_obj.put(a, "description", .{ .string = t.description });
            const params_val: std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, a, t.parameters, .{}) catch
                .{ .object = std.json.ObjectMap{} };
            try fn_obj.put(a, "parameters", params_val);

            var tool_obj = std.json.ObjectMap{};
            try tool_obj.put(a, "type", .{ .string = "function" });
            try tool_obj.put(a, "function", .{ .object = fn_obj });
            try tool_arr.append(.{ .object = tool_obj });
        }
        try root.put(a, "tools", .{ .array = tool_arr });
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// 悬空工具调用修复时使用的固定结果文案（稳定字符串，利于前缀缓存）
pub const interrupted_tool_result = "[Tool execution was interrupted: no result was recorded. Re-invoke the tool if needed.]";

/// 修复悬空工具调用：assistant 消息声明的每个 tool_call 都必须有对应 tool 结果，
/// 否则多数服务端（OpenAI / Anthropic 兼容）会拒绝整个请求（取消/中止会留下这种消息）。
/// 在既有结果之后为缺失的调用补一条固定文案的错误结果；无悬空时原样返回。
///
/// 注意：这是**请求层**的修复，落库内容不变——因此请求体可能与 DB 历史不同
/// （补出的结果行不落库，靠固定文案在此处确定性重建）。做请求体对比/缓存分析时
/// 请以本函数的输出（buildRequestBody 的产物）为准，而非直接序列化 DB 行。
fn repairDanglingToolCalls(a: Allocator, messages: []const Message) error{OutOfMemory}![]const Message {
    var has_calls = false;
    for (messages) |m| {
        if (std.mem.eql(u8, m.role, "assistant") and m.tool_calls != null) {
            has_calls = true;
            break;
        }
    }
    if (!has_calls) return messages; // 快速路径：原样序列化

    var out = std.ArrayListUnmanaged(Message){ .items = &.{}, .capacity = 0 };
    var i: usize = 0;
    while (i < messages.len) {
        const m = messages[i];
        try out.append(a, m);
        i += 1;
        if (!std.mem.eql(u8, m.role, "assistant")) continue;
        const calls = m.tool_calls orelse continue;
        if (calls.len == 0) continue;

        // 紧随其后的工具结果属于本批次
        const batch_start = out.items.len;
        while (i < messages.len and std.mem.eql(u8, messages[i].role, "tool")) : (i += 1) {
            try out.append(a, messages[i]);
        }
        for (calls) |c| {
            var found = false;
            for (out.items[batch_start..]) |r| {
                if (std.mem.eql(u8, r.tool_call_id orelse "", c.id)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try out.append(a, .{
                    .role = "tool",
                    .content = interrupted_tool_result,
                    .tool_call_id = c.id,
                });
            }
        }
    }
    return out.items;
}

fn messageToValue(a: Allocator, m: Message) error{OutOfMemory}!std.json.Value {
    var obj = std.json.ObjectMap{};
    try obj.put(a, "role", .{ .string = m.role });
    if (m.content.len == 0 and m.tool_calls != null) {
        try obj.put(a, "content", .null);
    } else {
        try obj.put(a, "content", .{ .string = m.content });
    }
    if (m.tool_call_id) |id| try obj.put(a, "tool_call_id", .{ .string = id });
    if (m.tool_calls) |calls| {
        var arr = std.json.Array.init(a);
        for (calls) |c| {
            var fn_obj = std.json.ObjectMap{};
            try fn_obj.put(a, "name", .{ .string = c.name });
            try fn_obj.put(a, "arguments", .{ .string = c.arguments });
            var call_obj = std.json.ObjectMap{};
            try call_obj.put(a, "id", .{ .string = c.id });
            try call_obj.put(a, "type", .{ .string = "function" });
            try call_obj.put(a, "function", .{ .object = fn_obj });
            try arr.append(.{ .object = call_obj });
        }
        try obj.put(a, "tool_calls", .{ .array = arr });
    }
    return .{ .object = obj };
}

/// 流式增量类型：正文或思考过程
pub const DeltaKind = enum { content, reasoning };

/// 流式增量回调：每收到一段正文/思考调用一次
pub const DeltaFn = *const fn (ctx: *anyopaque, kind: DeltaKind, delta: []const u8) void;

const StreamToolCallFunction = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const StreamToolCall = struct {
    index: u32 = 0,
    id: ?[]const u8 = null,
    function: ?StreamToolCallFunction = null,
};

const StreamDelta = struct {
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_calls: ?[]const StreamToolCall = null,
};

/// 把流式 tool_calls 分片按 index 合并为完整调用。
/// 传入的 allocator 应当是短生命周期 arena（内部按需复制字符串，不做逐项释放）。
pub const ToolCallAccumulator = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(ToolCall) = .{ .items = &.{}, .capacity = 0 },

    pub fn deinit(self: *ToolCallAccumulator) void {
        self.items.deinit(self.allocator);
        self.items = .{ .items = &.{}, .capacity = 0 };
    }

    pub fn feed(self: *ToolCallAccumulator, deltas: []const StreamToolCall) error{OutOfMemory}!void {
        for (deltas) |d| {
            while (self.items.items.len <= d.index) {
                try self.items.append(self.allocator, .{});
            }
            const item = &self.items.items[d.index];
            if (d.id) |id| {
                if (id.len > 0 and item.id.len == 0) item.id = try self.allocator.dupe(u8, id);
            }
            if (d.function) |f| {
                if (f.name) |name| {
                    if (name.len > 0 and item.name.len == 0) item.name = try self.allocator.dupe(u8, name);
                }
                if (f.arguments) |arg| {
                    if (arg.len > 0) {
                        item.arguments = try std.mem.concat(self.allocator, u8, &.{ item.arguments, arg });
                    }
                }
            }
        }
    }
};

const StreamChoice = struct {
    delta: StreamDelta = .{},
    /// 终止原因（"stop"/"tool_calls"/"length" 等）；非空表示本流已完整生成
    finish_reason: ?[]const u8 = null,
};

const StreamUsageDetails = struct {
    cached_tokens: i64 = 0,
};

const StreamUsage = struct {
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    /// OpenAI/OpenRouter/DeepSeek 缓存的字段各不相同
    prompt_cache_hit_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    prompt_tokens_details: ?StreamUsageDetails = null,
};

const StreamChunk = struct {
    choices: []const StreamChoice = &.{},
    usage: ?StreamUsage = null,
};

/// SSE 解析器：把字节流切成 data 行并提取 delta.content
pub const SseParser = struct {
    allocator: Allocator,
    line: std.ArrayListUnmanaged(u8) = .empty,
    finished: bool = false,
    /// 是否见过 finish_reason（部分兼容服务不发 [DONE]，两者任一均视为正常结束）
    saw_finish_reason: bool = false,
    /// 工具调用分片累积器（可选）
    tool_calls: ?*ToolCallAccumulator = null,
    /// token 用量输出（可选，最后一个 chunk 带回）
    usage: ?*Usage = null,

    pub fn deinit(self: *SseParser) void {
        self.line.deinit(self.allocator);
    }

    /// 喂入任意分片的字节，遇到完整 data 行时回调 on_delta
    pub fn feed(self: *SseParser, bytes: []const u8, ctx: *anyopaque, on_delta: DeltaFn) AIError!void {
        if (self.finished) return;
        var start: usize = 0;
        for (bytes, 0..) |b, i| {
            if (b != '\n') continue;
            self.line.appendSlice(self.allocator, bytes[start..i]) catch return error.OutOfMemory;
            start = i + 1;
            self.handleLine(ctx, on_delta) catch return error.OutOfMemory;
            if (self.finished) return;
        }
        self.line.appendSlice(self.allocator, bytes[start..]) catch return error.OutOfMemory;
    }

    fn handleLine(self: *SseParser, ctx: *anyopaque, on_delta: DeltaFn) error{OutOfMemory}!void {
        defer self.line.clearRetainingCapacity();
        var text: []const u8 = self.line.items;
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        if (!std.mem.startsWith(u8, text, "data:")) return;
        const payload = std.mem.trim(u8, text[5..], " \t");
        if (payload.len == 0) return;
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.finished = true;
            return;
        }
        var parsed = std.json.parseFromSlice(StreamChunk, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        // 用量（有的提供方只在最后一个 chunk 给）
        if (parsed.value.usage) |u| {
            if (self.usage) |out| {
                out.* = .{
                    .input_tokens = if (u.prompt_tokens > 0) @intCast(u.prompt_tokens) else 0,
                    .output_tokens = if (u.completion_tokens > 0) @intCast(u.completion_tokens) else 0,
                    .cached_tokens = @intCast(@max(0, cachedFromUsage(u))),
                };
            }
        }

        if (parsed.value.choices.len == 0) return;
        if (parsed.value.choices[0].finish_reason) |fr| {
            if (fr.len > 0) self.saw_finish_reason = true;
        }
        const d = parsed.value.choices[0].delta;
        if (d.content) |c| {
            if (c.len > 0) on_delta(ctx, .content, c);
        }
        if (d.reasoning_content) |r| {
            if (r.len > 0) on_delta(ctx, .reasoning, r);
        } else if (d.reasoning) |r| {
            if (r.len > 0) on_delta(ctx, .reasoning, r);
        }
        if (d.tool_calls) |calls| {
            if (self.tool_calls) |acc| try acc.feed(calls);
        }
    }
};

/// 从各家的 usage 字段里取缓存命中 token 数
fn cachedFromUsage(u: StreamUsage) i64 {
    if (u.prompt_tokens_details) |d| {
        if (d.cached_tokens > 0) return d.cached_tokens;
    }
    if (u.prompt_cache_hit_tokens > 0) return u.prompt_cache_hit_tokens;
    return u.cached_tokens;
}

pub const AIError = error{
    InvalidApiKey,
    NetworkError,
    InvalidResponse,
    JsonParseError,
    OutOfMemory,
    InvalidUri,
    ServerError,
    Canceled,
    /// 连接中途被关闭（EOF）且响应流未经 [DONE]/finish_reason 正常终止
    StreamTruncated,
    /// 服务端瞬时故障（429 限流 / 5xx）——属"可重试"类，由调用方决定退避重发
    ServerTransient,
};

pub const ModelInfo = struct {
    id: []const u8 = "",
};

pub const ModelsResponse = struct {
    data: []const ModelInfo = &.{},
};

/// 把非法 UTF-8 字节替换为 U+FFFD（返回新分配的内存）
pub fn sanitizeUtf8(allocator: Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < data.len) {
        const len = std.unicode.utf8ByteSequenceLength(data[i]) catch 1;
        if (len == 1) {
            if (data[i] < 0x80) {
                try out.append(allocator, data[i]);
            } else {
                try out.appendSlice(allocator, "\u{FFFD}");
            }
            i += 1;
        } else if (i + len <= data.len and std.unicode.utf8ValidateSlice(data[i .. i + len])) {
            try out.appendSlice(allocator, data[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const AI = struct {
    config: OpenAIConfig,
    allocator: Allocator,
    io: Io,
    /// 用于读取 HTTP(S)_PROXY 环境变量（可选）
    environ_map: ?*const std.process.Environ.Map = null,
    /// 最近一次请求的服务端错误响应体（供界面展示，调用 takeErrorBody 取走）
    error_body: ?[]u8 = null,
    /// 最近一次请求的 token 用量（含缓存命中）
    usage: Usage = .{},

    pub fn init(allocator: Allocator, io: Io, config: OpenAIConfig) AI {
        return .{
            .config = config,
            .allocator = allocator,
            .io = io,
        };
    }

    /// 读取错误响应体（最多 4KB，兼容 gzip 等压缩），非法字节替换为 U+FFFD
    fn captureErrorBody(self: *AI, response: *http.Client.Response) void {
        if (self.error_body) |old| self.allocator.free(old);
        self.error_body = null;

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .deflate, .gzip => self.allocator.alloc(u8, std.compress.flate.max_window_len) catch return,
            .zstd => self.allocator.alloc(u8, std.compress.zstd.default_window_len) catch return,
            .compress => &.{},
        };
        defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

        var transfer_buf: [512]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);

        var read_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < read_buf.len) {
            const n = reader.readSliceShort(read_buf[total..]) catch 0;
            if (n == 0) break;
            total += n;
        }
        if (total == 0) return;
        self.error_body = sanitizeUtf8(self.allocator, read_buf[0..total]) catch null;
    }

    /// 取走错误响应体（所有权转移给调用方）
    pub fn takeErrorBody(self: *AI) ?[]u8 {
        const body = self.error_body;
        self.error_body = null;
        return body;
    }

    /// 创建带代理支持的 HTTP 客户端（proxy_arena 需比客户端活得久）
    fn makeClient(self: *AI, proxy_arena: Allocator) http.Client {
        var client: http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        if (self.environ_map) |env| {
            client.initDefaultProxies(proxy_arena, env) catch {};
        }
        return client;
    }

    /// 构建会话路由头与自定义头（按 affinity 方言）：
    /// zen → x-opencode-session/client；openai → session_id/x-client-request-id/x-session-affinity；
    /// openrouter → x-session-id；fireworks → x-session-affinity
    fn appendBehaviorHeaders(self: *AI, headers: *std.ArrayListUnmanaged(http.Header)) void {
        const session_id = self.config.session_id;
        if (session_id.len > 0) {
            switch (self.config.behavior.affinity) {
                .opencode => {
                    headers.append(self.allocator, .{ .name = "x-opencode-session", .value = session_id }) catch return;
                    headers.append(self.allocator, .{ .name = "x-opencode-client", .value = "skynet" }) catch return;
                },
                .openai => {
                    headers.append(self.allocator, .{ .name = "session_id", .value = session_id }) catch return;
                    headers.append(self.allocator, .{ .name = "x-client-request-id", .value = session_id }) catch return;
                    headers.append(self.allocator, .{ .name = "x-session-affinity", .value = session_id }) catch return;
                },
                .openrouter => {
                    headers.append(self.allocator, .{ .name = "x-session-id", .value = session_id }) catch return;
                },
                .fireworks => {
                    headers.append(self.allocator, .{ .name = "x-session-affinity", .value = session_id }) catch return;
                },
                .none => {},
            }
        }
        for (self.config.behavior.extra_headers) |h| {
            if (h.name.len == 0) continue;
            headers.append(self.allocator, .{ .name = h.name, .value = h.value }) catch return;
        }
    }

    // 读取响应体：支持 Content-Length、chunked 传输编码与 gzip/deflate/zstd 压缩
    fn readResponseBody(self: *AI, response: *http.Client.Response, max_bytes: usize) AIError![]u8 {
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .deflate, .gzip => self.allocator.alloc(u8, std.compress.flate.max_window_len) catch
                return error.OutOfMemory,
            .zstd => self.allocator.alloc(u8, std.compress.zstd.default_window_len) catch
                return error.OutOfMemory,
            .compress => return error.InvalidResponse,
        };
        defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

        var transfer_buf: [4096]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);
        return reader.allocRemaining(self.allocator, .limited(max_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.InvalidResponse,
            else => return error.NetworkError,
        };
    }

    /// 流式请求：每段增量通过 on_delta 回调；cancel 置位后尽快返回 error.Canceled
    pub fn streamMessage(
        self: *AI,
        history: []const Message,
        tools: []const ToolSchema,
        cancel: *std.atomic.Value(bool),
        ctx: *anyopaque,
        on_delta: DeltaFn,
        tool_calls: ?*ToolCallAccumulator,
    ) AIError!void {
        self.usage = .{};
        const t0 = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        Log.info(.api, "请求 model={s} 消息={d} 工具={d}", .{ self.config.model, history.len, tools.len });
        const body_json = try buildRequestBody(
            self.allocator,
            self.config.model,
            history,
            tools,
            self.config.session_id,
            self.config.behavior,
        );
        defer self.allocator.free(body_json);

        // Build full URL
        const base = self.config.endpoint;
        const suffix = "/chat/completions";
        const full_url = if (std.mem.endsWith(u8, base, suffix))
            base
        else blk: {
            const len = base.len + suffix.len;
            const buf = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
            @memcpy(buf[0..base.len], base);
            @memcpy(buf[base.len..len], suffix);
            break :blk buf;
        };
        defer if (full_url.ptr != base.ptr) self.allocator.free(full_url);

        const uri = Uri.parse(full_url) catch return error.InvalidUri;

        const auth_header: ?[]const u8 = if (self.config.api_key.len > 0)
            std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key}) catch return error.OutOfMemory
        else
            null;
        defer if (auth_header) |h| self.allocator.free(h);

        // Create a fresh client for each request to avoid stale connections
        var proxy_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer proxy_arena.deinit();
        var client = self.makeClient(proxy_arena.allocator());
        defer client.deinit();

        var extra_headers = std.ArrayListUnmanaged(http.Header){ .items = &.{}, .capacity = 0 };
        defer extra_headers.deinit(self.allocator);
        self.appendBehaviorHeaders(&extra_headers);

        var request = client.request(.POST, uri, .{
            .keep_alive = false,
            .extra_headers = extra_headers.items,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .authorization = if (auth_header) |h| .{ .override = h } else .omit,
                .content_type = .{ .override = "application/json" },
            },
        }) catch return error.NetworkError;
        defer request.deinit();

        request.sendBodyComplete(body_json) catch return error.NetworkError;

        var redirect_buf: [4096]u8 = undefined;
        var response = request.receiveHead(&redirect_buf) catch return error.NetworkError;

        const status = response.head.status;
        if (status.class() != .success) {
            // 非成功响应记录状态码：此前该信息在错误分类中被静默丢弃，事后无从诊断
            Log.warn(.api, "HTTP {s}（非成功响应）", .{@tagName(status)});
        }
        if (status == .unauthorized) return error.InvalidApiKey;
        // 429 限流与 5xx：服务端瞬时故障 → 可重试（对齐 pi/opencode 的重试面）
        if (status == .too_many_requests or status.class() == .server_error) {
            self.captureErrorBody(&response);
            return error.ServerTransient;
        }
        if (status == .not_found or status == .bad_request or status == .forbidden) {
            self.captureErrorBody(&response);
            return error.ServerError;
        }
        if (status.class() != .success) {
            self.captureErrorBody(&response);
            return error.InvalidResponse;
        }

        // 逐块读取响应体（兼容 chunked 与 gzip 等压缩）
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .deflate, .gzip => self.allocator.alloc(u8, std.compress.flate.max_window_len) catch
                return error.OutOfMemory,
            .zstd => self.allocator.alloc(u8, std.compress.zstd.default_window_len) catch
                return error.OutOfMemory,
            .compress => return error.InvalidResponse,
        };
        defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

        var transfer_buf: [4096]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);

        var parser = SseParser{ .allocator = self.allocator, .tool_calls = tool_calls, .usage = &self.usage };
        defer parser.deinit();

        var read_buf: [4096]u8 = undefined;
        while (!parser.finished) {
            if (cancel.load(.acquire)) return error.Canceled;
            const n = reader.readSliceShort(&read_buf) catch return error.NetworkError;
            if (n == 0) break;
            try parser.feed(read_buf[0..n], ctx, on_delta);
        }
        // 对端关闭连接（EOF）且流未经 [DONE]/finish_reason 正常终止 → 判定为截断。
        // 否则"纯思考/部分内容被截断"会被当成正常结束：用户只看到输出停住、无任何提示。
        if (!parser.finished and !parser.saw_finish_reason) {
            if (cancel.load(.acquire)) return error.Canceled;
            Log.warn(.api, "流被截断（无 [DONE]/finish_reason）({d}ms)", .{std.Io.Timestamp.now(self.io, .awake).toMilliseconds() - t0});
            return error.StreamTruncated;
        }
        Log.info(.api, "响应 {d}ms in={d} cached={d} out={d}", .{
            std.Io.Timestamp.now(self.io, .awake).toMilliseconds() - t0,
            self.usage.input_tokens,
            self.usage.cached_tokens,
            self.usage.output_tokens,
        });
    }

    pub fn listModels(self: *AI) AIError![]ModelInfo {
        const base = self.config.endpoint;
        const full_url = blk: {
            if (std.mem.endsWith(u8, base, "/v1")) {
                const suffix = "/models";
                const len = base.len + suffix.len;
                const buf = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
                @memcpy(buf[0..base.len], base);
                @memcpy(buf[base.len..len], suffix);
                break :blk buf;
            }
            if (std.mem.endsWith(u8, base, "/")) {
                const suffix = "models";
                const len = base.len + suffix.len;
                const buf = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
                @memcpy(buf[0..base.len], base);
                @memcpy(buf[base.len..len], suffix);
                break :blk buf;
            }
            const suffix = "/models";
            const len = base.len + suffix.len;
            const buf = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
            @memcpy(buf[0..base.len], base);
            @memcpy(buf[base.len..len], suffix);
            break :blk buf;
        };
        defer self.allocator.free(full_url);

        const uri = Uri.parse(full_url) catch return error.InvalidUri;

        const auth_header: ?[]const u8 = if (self.config.api_key.len > 0)
            std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.config.api_key}) catch return error.OutOfMemory
        else
            null;
        defer if (auth_header) |h| self.allocator.free(h);

        // 与 streamMessage 使用相同的 HTTP 客户端模式
        var proxy_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer proxy_arena.deinit();
        var client = self.makeClient(proxy_arena.allocator());
        defer client.deinit();

        var extra_headers = std.ArrayListUnmanaged(http.Header){ .items = &.{}, .capacity = 0 };
        defer extra_headers.deinit(self.allocator);
        self.appendBehaviorHeaders(&extra_headers);

        var request = client.request(.GET, uri, .{
            .keep_alive = false,
            .extra_headers = extra_headers.items,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .authorization = if (auth_header) |h| .{ .override = h } else .omit,
            },
        }) catch return error.NetworkError;
        defer request.deinit();

        // GET 请求使用 sendBodiless
        request.sendBodiless() catch return error.NetworkError;

        var redirect_buf: [4096]u8 = undefined;
        var response = request.receiveHead(&redirect_buf) catch return error.NetworkError;

        const status = response.head.status;
        if (status == .unauthorized) return error.InvalidApiKey;
        if (status.class() != .success) return error.ServerError;

        // 读取响应体（兼容 chunked 与 gzip 压缩）
        const response_body = try self.readResponseBody(&response, 4 * 1024 * 1024);
        defer self.allocator.free(response_body);

        var parsed = std.json.parseFromSlice(ModelsResponse, self.allocator, response_body, .{
            .ignore_unknown_fields = true,
        }) catch {
            return &[_]ModelInfo{};
        };
        defer parsed.deinit();

        // 深拷贝：复制每个模型的 id 字符串
        const models = parsed.value.data;
        const result = self.allocator.alloc(ModelInfo, models.len) catch return error.OutOfMemory;
        for (models, 0..) |model, i| {
            result[i] = .{
                .id = self.allocator.dupe(u8, model.id) catch {
                    // 部分分配失败，释放已分配的
                    for (result[0..i]) |m| {
                        self.allocator.free(m.id);
                    }
                    self.allocator.free(result);
                    return error.OutOfMemory;
                },
            };
        }
        return result;
    }
};

test "sanitizeUtf8 替换非法字节" {
    const valid = "你好abc";
    const a = try sanitizeUtf8(std.testing.allocator, valid);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings(valid, a);

    // 0xFF 非法；0xC3 0x28 不构成合法序列；单字节 >0x7F 非法
    const invalid = [_]u8{ 'a', 0xFF, 'b', 0xC3, 0x28, 'c' };
    const b = try sanitizeUtf8(std.testing.allocator, &invalid);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}(c", b);

    // 截断的多字节序列
    const truncated = [_]u8{ 0xE4, 0xBD };
    const c = try sanitizeUtf8(std.testing.allocator, &truncated);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD}", c);
}

test "opencode 端点识别与请求头" {
    try std.testing.expect(isOpenCodeEndpoint("https://opencode.ai/zen/go/v1"));
    try std.testing.expect(isOpenCodeEndpoint("https://OPENCODE.AI/x"));
    try std.testing.expect(isOpenCodeEndpoint("https://user@opencode.ai:443/v1"));
    try std.testing.expect(!isOpenCodeEndpoint("http://127.0.0.1:1234/v1"));
    try std.testing.expect(!isOpenCodeEndpoint("https://api.openai.com/v1"));
    try std.testing.expect(!isOpenCodeEndpoint("https://notopencode.ai/v1"));
    try std.testing.expect(!isOpenCodeEndpoint("opencode.ai/v1"));

    var client = AI.init(std.testing.allocator, undefined, .{
        .api_key = "",
        .endpoint = "https://opencode.ai/zen/go/v1",
        .model = "m",
        .session_id = "abc",
        .behavior = .{ .affinity = .opencode },
    });
    var headers = std.ArrayListUnmanaged(http.Header){ .items = &.{}, .capacity = 0 };
    defer headers.deinit(std.testing.allocator);
    client.appendBehaviorHeaders(&headers);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("x-opencode-session", headers.items[0].name);
    try std.testing.expectEqualStrings("abc", headers.items[0].value);
    try std.testing.expectEqualStrings("x-opencode-client", headers.items[1].name);
    try std.testing.expectEqualStrings("skynet", headers.items[1].value);

    // 非 opencode 方言：不发这两个头
    var other = AI.init(std.testing.allocator, undefined, .{
        .api_key = "",
        .endpoint = "http://127.0.0.1:1234/v1",
        .model = "m",
        .session_id = "abc",
    });
    var headers2 = std.ArrayListUnmanaged(http.Header){ .items = &.{}, .capacity = 0 };
    defer headers2.deinit(std.testing.allocator);
    other.appendBehaviorHeaders(&headers2);
    try std.testing.expectEqual(@as(usize, 0), headers2.items.len);
}

test "请求头：各家会话亲和方言 + 自定义头" {
    const cases = [_]struct {
        affinity: Affinity,
        expected: []const []const u8,
    }{
        .{ .affinity = .openai, .expected = &.{ "session_id", "x-client-request-id", "x-session-affinity" } },
        .{ .affinity = .openrouter, .expected = &.{"x-session-id"} },
        .{ .affinity = .fireworks, .expected = &.{"x-session-affinity"} },
        .{ .affinity = .none, .expected = &.{} },
    };
    for (cases) |case| {
        const extra = [_]config_mod.HeaderKV{.{ .name = "X-Org", .value = "acme" }};
        var client = AI.init(std.testing.allocator, undefined, .{
            .api_key = "",
            .model = "m",
            .session_id = "sess-1",
            .behavior = .{ .affinity = case.affinity, .extra_headers = &extra },
        });
        var headers = std.ArrayListUnmanaged(http.Header){ .items = &.{}, .capacity = 0 };
        defer headers.deinit(std.testing.allocator);
        client.appendBehaviorHeaders(&headers);

        try std.testing.expectEqual(case.expected.len + 1, headers.items.len);
        for (case.expected, 0..) |name, i| {
            try std.testing.expectEqualStrings(name, headers.items[i].name);
            try std.testing.expectEqualStrings("sess-1", headers.items[i].value);
        }
        const last = headers.items[headers.items.len - 1];
        try std.testing.expectEqualStrings("X-Org", last.name);
        try std.testing.expectEqualStrings("acme", last.value);
    }
}

test "请求体：缓存参数与流式 usage" {
    const messages = [_]Message{.{ .role = "user", .content = "hi" }};

    // 开启缓存 key（short）→ 只有 prompt_cache_key；usage 默认开启（跟随服务端默认值）
    const short_body = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "sess-1", .{
        .cache_key = true,
        .retention = .short,
    });
    defer std.testing.allocator.free(short_body);
    try std.testing.expect(std.mem.indexOf(u8, short_body, "\"prompt_cache_key\":\"sess-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_body, "prompt_cache_retention") == null);
    try std.testing.expect(std.mem.indexOf(u8, short_body, "\"include_usage\":true") != null);

    // 显式关闭 include_usage（个别网关不认 stream_options 时的逃生门）→ 不出现
    const no_usage = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "sess-1", .{
        .cache_key = true,
        .retention = .short,
        .include_usage = false,
    });
    defer std.testing.allocator.free(no_usage);
    try std.testing.expect(std.mem.indexOf(u8, no_usage, "stream_options") == null);

    // long → 24h 保留 + stream_options
    const long_body = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "sess-1", .{
        .cache_key = true,
        .retention = .long,
    });
    defer std.testing.allocator.free(long_body);
    try std.testing.expect(std.mem.indexOf(u8, long_body, "\"prompt_cache_retention\":\"24h\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, long_body, "\"include_usage\":true") != null);

    // 不发送 temperature：使用服务端默认值
    try std.testing.expect(std.mem.indexOf(u8, short_body, "temperature") == null);
    try std.testing.expect(std.mem.indexOf(u8, long_body, "temperature") == null);

    // 无 session_id → 不发 key；超长 key 截断到 64
    const no_sess = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "", .{ .cache_key = true });
    defer std.testing.allocator.free(no_sess);
    try std.testing.expect(std.mem.indexOf(u8, no_sess, "prompt_cache_key") == null);

    const long_id = "x" ** 100;
    const clamped = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, long_id, .{ .cache_key = true });
    defer std.testing.allocator.free(clamped);
    try std.testing.expect(std.mem.indexOf(u8, clamped, "prompt_cache_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, clamped, long_id) == null);
}

test "请求体：思考强度（reasoning_effort / deepseek thinking）" {
    const messages = [_]Message{.{ .role = "user", .content = "hi" }};

    // 通用 openai 兼容：只发 reasoning_effort
    const b1 = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "", .{ .reasoning_effort = "max" });
    defer std.testing.allocator.free(b1);
    try std.testing.expect(std.mem.indexOf(u8, b1, "\"reasoning_effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b1, "\"thinking\"") == null);

    // DeepSeek 直连：thinking enabled + effort
    const b2 = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "", .{
        .reasoning_effort = "high",
        .deepseek_thinking = true,
    });
    defer std.testing.allocator.free(b2);
    try std.testing.expect(std.mem.indexOf(u8, b2, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b2, "\"thinking\":{\"type\":\"enabled\"}") != null);

    // off：DeepSeek 发 disabled 且不带 effort；普通 provider 两个都不发
    const b3 = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "", .{
        .reasoning_effort = "off",
        .deepseek_thinking = true,
    });
    defer std.testing.allocator.free(b3);
    try std.testing.expect(std.mem.indexOf(u8, b3, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, b3, "reasoning_effort") == null);

    const b4 = try buildRequestBody(std.testing.allocator, "m", &messages, &.{}, "", .{ .reasoning_effort = "off" });
    defer std.testing.allocator.free(b4);
    try std.testing.expect(std.mem.indexOf(u8, b4, "thinking") == null);
    try std.testing.expect(std.mem.indexOf(u8, b4, "reasoning_effort") == null);
}

test "SSE 解析：usage 缓存字段（三家命名）" {
    var collector = TestCollector{};
    defer collector.deinit();

    // OpenAI 风格：prompt_tokens_details.cached_tokens
    var usage = Usage{};
    var parser = SseParser{ .allocator = std.testing.allocator, .usage = &usage };
    defer parser.deinit();
    try parser.feed("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":80}}}\n", &collector, TestCollector.append);
    try std.testing.expectEqual(@as(u64, 100), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 80), usage.cached_tokens);

    // DeepSeek 风格：prompt_cache_hit_tokens（无 choices）
    var usage2 = Usage{};
    var parser2 = SseParser{ .allocator = std.testing.allocator, .usage = &usage2 };
    defer parser2.deinit();
    try parser2.feed("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":200,\"completion_tokens\":7,\"prompt_cache_hit_tokens\":150,\"prompt_cache_miss_tokens\":50}}\n", &collector, TestCollector.append);
    try std.testing.expectEqual(@as(u64, 150), usage2.cached_tokens);
}

const TestCollector = struct {
    content: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *TestCollector) void {
        self.content.deinit(std.testing.allocator);
        self.reasoning.deinit(std.testing.allocator);
    }

    fn append(ctx: *anyopaque, kind: DeltaKind, delta: []const u8) void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx));
        const target = if (kind == .reasoning) &self.reasoning else &self.content;
        target.appendSlice(std.testing.allocator, delta) catch {};
    }
};

test "SSE 解析：正常行、Cross-feed 分片、CRLF" {
    var collector = TestCollector{};
    defer collector.deinit();

    var parser = SseParser{ .allocator = std.testing.allocator };
    defer parser.deinit();

    // 一次性完整的行（含 CRLF）
    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\r\n", &collector, TestCollector.append);
    // 跨两次 feed 的 JSON 分片
    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"世", &collector, TestCollector.append);
    try parser.feed("界\"}}]}\n", &collector, TestCollector.append);
    // 无空格写法
    try parser.feed("data:{\"choices\":[{\"delta\":{\"content\":\"!\"}}]}\n", &collector, TestCollector.append);
    // 最后一行未换行：保留在缓冲中不产生内容
    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"?\"}}]}", &collector, TestCollector.append);
    try std.testing.expectEqualStrings("你好世界!", collector.content.items);

    // 补上换行后处理
    try parser.feed("\n", &collector, TestCollector.append);
    try std.testing.expectEqualStrings("你好世界!?", collector.content.items);
    try std.testing.expect(!parser.finished);
}

test "SSE 解析：[DONE] 终止、忽略非 data 行与无效 JSON" {
    var collector = TestCollector{};
    defer collector.deinit();

    var parser = SseParser{ .allocator = std.testing.allocator };
    defer parser.deinit();

    try parser.feed(": keepalive\n", &collector, TestCollector.append);
    try parser.feed("event: message\n", &collector, TestCollector.append);
    try parser.feed("data: {invalid json}\n", &collector, TestCollector.append);
    // role-only 的 delta 不产生内容
    try parser.feed("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n", &collector, TestCollector.append);
    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n", &collector, TestCollector.append);
    try parser.feed("data: [DONE]\n", &collector, TestCollector.append);

    try std.testing.expectEqualStrings("ok", collector.content.items);
    try std.testing.expect(parser.finished);

    // 结束后再喂数据不再产生内容
    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n", &collector, TestCollector.append);
    try std.testing.expectEqualStrings("ok", collector.content.items);
}

test "SSE 解析：空行与 data: 空载荷" {
    var collector = TestCollector{};
    defer collector.deinit();

    var parser = SseParser{ .allocator = std.testing.allocator };
    defer parser.deinit();

    try parser.feed("\n", &collector, TestCollector.append);
    try parser.feed("data:\n", &collector, TestCollector.append);
    try parser.feed("data: \n", &collector, TestCollector.append);
    try std.testing.expectEqual(@as(usize, 0), collector.content.items.len);
    try std.testing.expect(!parser.finished);
}

test "SSE 解析：思考字段（reasoning_content 与 reasoning）" {
    var collector = TestCollector{};
    defer collector.deinit();

    var parser = SseParser{ .allocator = std.testing.allocator };
    defer parser.deinit();

    try parser.feed("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"让我想\"}}]}\n", &collector, TestCollector.append);
    // OpenRouter 风格的 reasoning 字段
    try parser.feed("data: {\"choices\":[{\"delta\":{\"reasoning\":\"想\"}}]}\n", &collector, TestCollector.append);
    // content 为 null 不应报错，也不产生正文
    try parser.feed("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null}}]}\n", &collector, TestCollector.append);
    // 正文开始
    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"答案\"}}]}\n", &collector, TestCollector.append);

    try std.testing.expectEqualStrings("让我想想", collector.reasoning.items);
    try std.testing.expectEqualStrings("答案", collector.content.items);
}

test "SSE 解析：finish_reason 终止标志（截断检测前提）" {
    var collector = TestCollector{};
    defer collector.deinit();

    var parser = SseParser{ .allocator = std.testing.allocator };
    defer parser.deinit();

    // 只有思考增量：两个终止标志都未置位 —— 此时若连接断开应判定为截断
    try parser.feed("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想\"}}]}\n", &collector, TestCollector.append);
    try std.testing.expect(!parser.finished);
    try std.testing.expect(!parser.saw_finish_reason);

    // 显式 null / 空串不算完成
    try parser.feed("data: {\"choices\":[{\"delta\":{},\"finish_reason\":null}]}\n", &collector, TestCollector.append);
    try parser.feed("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\"}]}\n", &collector, TestCollector.append);
    try std.testing.expect(!parser.saw_finish_reason);

    // finish_reason 置位（部分兼容服务只发它、不发 [DONE]）
    try parser.feed("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n", &collector, TestCollector.append);
    try std.testing.expect(parser.saw_finish_reason);

    // [DONE] 仍正常置 finished（与 finish_reason 两者任一即可判定完成）
    try parser.feed("data: [DONE]\n\n", &collector, TestCollector.append);
    try std.testing.expect(parser.finished);
}

test "SSE 解析：[DONE] 单独出现也判定完成（保持兼容）" {
    var collector = TestCollector{};
    defer collector.deinit();

    var parser = SseParser{ .allocator = std.testing.allocator };
    defer parser.deinit();

    try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n", &collector, TestCollector.append);
    try parser.feed("data: [DONE]\n", &collector, TestCollector.append);
    try std.testing.expect(parser.finished);
    try std.testing.expect(!parser.saw_finish_reason);
}

test "工具调用分片累积" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var acc = ToolCallAccumulator{ .allocator = arena_state.allocator() };
    defer acc.deinit();

    var collector = TestCollector{};
    defer collector.deinit();

    var parser = SseParser{ .allocator = std.testing.allocator, .tool_calls = &acc };
    defer parser.deinit();

    try parser.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}\n", &collector, TestCollector.append);
    try parser.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a.txt\\\"}\"}}]}}]}\n", &collector, TestCollector.append);
    try parser.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_2\",\"function\":{\"name\":\"ls\",\"arguments\":\"{}\"}}]}}]}\n", &collector, TestCollector.append);

    try std.testing.expectEqual(@as(usize, 2), acc.items.items.len);
    try std.testing.expectEqualStrings("call_1", acc.items.items[0].id);
    try std.testing.expectEqualStrings("read", acc.items.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", acc.items.items[0].arguments);
    try std.testing.expectEqualStrings("call_2", acc.items.items[1].id);
    try std.testing.expectEqualStrings("ls", acc.items.items[1].name);
    try std.testing.expectEqualStrings("{}", acc.items.items[1].arguments);
}

test "请求体：工具定义与工具消息" {
    const messages = [_]Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a.txt\"}" }} },
        .{ .role = "tool", .content = "file content", .tool_call_id = "call_1" },
    };
    const tools = [_]ToolSchema{.{ .name = "read", .description = "Read", .parameters = "{\"type\":\"object\"}" }};
    const body = try buildRequestBody(std.testing.allocator, "m", &messages, &tools, "", .{});
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":null") != null);
}

test "请求体：悬空工具调用自动补齐固定结果（取消/中止场景）" {
    const alloc = std.testing.allocator;

    // 场景 A：3 个调用只有 1 个结果（工具批次中途取消）→ 补 2 条固定文案结果
    const messages = [_]Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "干活" },
        .{
            .role = "assistant",
            .content = "",
            .tool_calls = &.{
                .{ .id = "c1", .name = "read", .arguments = "{}" },
                .{ .id = "c2", .name = "bash", .arguments = "{}" },
                .{ .id = "c3", .name = "grep", .arguments = "{}" },
            },
        },
        .{ .role = "tool", .content = "结果1", .tool_call_id = "c1" },
        // 注意：这里没有 c2/c3 的结果
        .{ .role = "user", .content = "继续" },
    };
    const body = try buildRequestBody(alloc, "m", &messages, &.{}, "sess", .{});
    defer alloc.free(body);
    // 补齐：固定文案出现在请求体，且 tool_call_id 对得上
    try std.testing.expect(std.mem.indexOf(u8, body, interrupted_tool_result) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c3\"") != null);
    // 原有结果保留且只出现一次
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"结果1\""));
    // 补齐结果必须插在"继续"之前（工具结果紧跟批次）
    const pos_c2 = std.mem.indexOf(u8, body, "\"tool_call_id\":\"c2\"").?;
    const pos_next_user = std.mem.indexOf(u8, body, "继续").?;
    try std.testing.expect(pos_c2 < pos_next_user);

    // 场景 B：调用全部有结果 → 请求体不出现固定文案（不干扰正常路径）
    const complete = [_]Message{
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "c1", .name = "read", .arguments = "{}" }} },
        .{ .role = "tool", .content = "ok", .tool_call_id = "c1" },
    };
    const body_b = try buildRequestBody(alloc, "m", &complete, &.{}, "sess", .{});
    defer alloc.free(body_b);
    try std.testing.expect(std.mem.indexOf(u8, body_b, interrupted_tool_result) == null);

    // 场景 C：确定性（同输入两次构建逐字节相同，前缀缓存可用）
    const body_c1 = try buildRequestBody(alloc, "m", &messages, &.{}, "sess", .{});
    defer alloc.free(body_c1);
    const body_c2 = try buildRequestBody(alloc, "m", &messages, &.{}, "sess", .{});
    defer alloc.free(body_c2);
    try std.testing.expectEqualStrings(body_c1, body_c2);

    // 场景 D：多个悬空批次（连续两个被取消的工具轮）互不干扰
    const two_batches = [_]Message{
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "a1", .name = "read", .arguments = "{}" }} },
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "b1", .name = "bash", .arguments = "{}" }} },
        .{ .role = "user", .content = "再来" },
    };
    const body_d = try buildRequestBody(alloc, "m", &two_batches, &.{}, "sess", .{});
    defer alloc.free(body_d);
    try std.testing.expect(std.mem.indexOf(u8, body_d, "\"tool_call_id\":\"a1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_d, "\"tool_call_id\":\"b1\"") != null);
    // a1 的补齐结果在 b1 的 assistant 消息之前
    const pos_a1 = std.mem.indexOf(u8, body_d, "\"tool_call_id\":\"a1\"").?;
    const pos_b1_call = std.mem.indexOf(u8, body_d, "\"id\":\"b1\"").?;
    try std.testing.expect(pos_a1 < pos_b1_call);
}

test "请求体：真实工具 schema（线程内构建，回归 arena UAF）" {
    const tools_mod = @import("tools.zig");
    const T = struct {
        fn run() void {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const a = arena_state.allocator();

            var schemas: [tools_mod.tool_defs.len]ToolSchema = undefined;
            for (tools_mod.tool_defs, 0..) |d, i| {
                schemas[i] = .{ .name = d.name, .description = d.description, .parameters = d.parameters };
            }

            var messages = std.ArrayListUnmanaged(Message){ .items = &.{}, .capacity = 0 };
            messages.append(a, .{ .role = "user", .content = "列一下目录" }) catch return;
            const body = buildRequestBody(a, "mock-model", messages.items, &schemas, "", .{}) catch return;
            if (std.mem.indexOf(u8, body, "\"tools\"") == null) @panic("no tools");
            if (std.mem.indexOf(u8, body, "\"required\"") == null) @panic("missing edit schema fields");
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{});
    t.join();
}
