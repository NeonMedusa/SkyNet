//! 上下文管理纯计算：token 估算、工具输出折叠模拟、压缩区间选择与摘要输入构建。
//! 不依赖 AppState / UI，便于单测与复用。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ai = @import("ai.zig");
const tools_mod = @import("tools.zig");
const utf8 = @import("utf8.zig");

// ── token 估算 ──

/// 估算 token（约 4 字符 = 1 token）
pub fn estimateTokens(bytes: usize) usize {
    return (bytes + 3) / 4;
}

/// 工具 schema 的总字节数（请求固定开销）
pub fn toolsSchemaBytes() usize {
    var n: usize = 0;
    for (tools_mod.tool_defs) |d| n += d.name.len + d.description.len + d.parameters.len;
    return n;
}

/// 单条消息进入请求的近似字节数（正文 + tool_calls 参数）。
/// `count_reasoning`：当前模型回传思考（能力表 interleaved 非空）时，assistant 的
/// reasoning 字段也会进请求，计入估算才能保证"估算 = 实际发送量"（与 messageToValue
/// 的发送条件逐字对应：interleaved 非空 且 role = assistant）。
pub fn messageRequestBytes(m: ai.Message, count_reasoning: bool) usize {
    var n: usize = m.content.len;
    if (count_reasoning and std.mem.eql(u8, m.role, "assistant")) n += m.reasoning.len;
    if (m.tool_calls) |cs| {
        for (cs) |c| n += c.arguments.len + 32;
    }
    return n;
}

/// 一段历史的近似请求字节数
pub fn historyRequestBytesSlice(history: []const ai.Message, count_reasoning: bool) usize {
    var bytes: usize = 0;
    for (history) |m| bytes += messageRequestBytes(m, count_reasoning);
    return bytes;
}

// ── 上下文溢出错误识别（P2 自愈：溢出 → 自动压缩 → 重试一次）──

/// 大小写不敏感子串查找（模式均为 ASCII）
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len) : (k += 1) {
            if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(needle[k])) break;
        }
        if (k == needle.len) return true;
    }
    return false;
}

/// 错误体是否表示"输入超出上下文窗口"（参考 pi / opencode 的厂商错误模式表；
/// 取通用子串而非全量正则）。仅认输入超限类；排除限流/瞬时故障以免误判。
pub fn isContextOverflowText(msg: []const u8) bool {
    if (msg.len == 0) return false;
    const excludes = [_][]const u8{
        "rate limit",  "too many requests", "throttling", "service unavailable",
        "please wait", "overloaded",
    };
    for (excludes) |p| if (containsIgnoreCase(msg, p)) return false;
    const patterns = [_][]const u8{
        "prompt is too long",
        "prompt too long",
        "request_too_large",
        "input is too long",
        "exceeds the context window",
        "maximum context length",
        "context_length_exceeded",
        "context length is only",
        "context length exceeded",
        "reduce the length of the messages",
        "maximum prompt length is",
        "exceeds the maximum allowed input length",
        "longer than the model's context length",
        "exceeds the available context size",
        "greater than the context length",
        "context window exceeds limit",
        "exceeded model token limit",
        "too large for model with",
        "configured context size is",
        "model_context_window_exceeded",
        "token limit exceeded",
    };
    for (patterns) |p| if (containsIgnoreCase(msg, p)) return true;
    return false;
}

// ── 工具输出折叠 ──

/// 保护最近约 160KB（≈40k tokens）的工具输出；可折叠量达到约 80KB（≈20k tokens）才批量折叠
pub const fold_protect_bytes: usize = 160 * 1024;
pub const fold_min_bytes: usize = 80 * 1024;
/// 最近 N 个用户回合内的工具输出一律不折叠（位置保护：用户可能仍在追问它们）
pub const fold_protect_turns: usize = 2;
/// 单条输出小于该值不折叠：stub + 未来重调的成本与收益相当
pub const fold_min_output_bytes: usize = 1024;
/// 已折叠 stub 的识别前缀
pub const fold_marker = "[工具输出已折叠";

pub const FoldSim = struct {
    foldable_bytes: usize = 0,
    foldable_count: usize = 0,
    triggered: bool = false,
};

/// 折叠扫描器：从新到旧逐条喂入，统一 /context 模拟与真实折叠的判定规则。
/// 规则：
/// 1. 最近 fold_protect_turns 个用户回合内的工具输出不折（位置保护）
/// 2. 遇到已折叠的（folded 标记）即停（更早的内容早已处理过，无需继续扫描）
/// 3. 单条小于 fold_min_output_bytes 不折
/// 4. 最近 fold_protect_bytes 字节（从新到旧累计）受保护，更早的才算候选
pub const FoldScanner = struct {
    protected_bytes: usize = 0,
    user_turns: usize = 0,
    foldable_bytes: usize = 0,
    foldable_count: usize = 0,

    pub const Action = enum { skip, stop, candidate };

    /// persistable：工具结果是否已落库（未落库的不能折叠，否则重启后请求前缀不一致）
    /// already_folded：DB 中该行已标记折叠（`message.folded`）——不依赖 content 判断
    /// （折叠仅面向 AI，content 始终是全文）
    pub fn feed(self: *FoldScanner, role: []const u8, content: []const u8, persistable: bool, already_folded: bool) Action {
        if (std.mem.eql(u8, role, "user")) {
            self.user_turns += 1;
            return .skip;
        }
        if (!std.mem.eql(u8, role, "tool")) return .skip;
        if (content.len == 0) return .skip;
        if (self.user_turns < fold_protect_turns) return .skip;
        if (already_folded) return .stop;
        if (content.len < fold_min_output_bytes) return .skip;
        if (!persistable) return .skip;
        if (self.protected_bytes < fold_protect_bytes) {
            self.protected_bytes += content.len;
            return .skip;
        }
        self.foldable_bytes += content.len;
        self.foldable_count += 1;
        return .candidate;
    }

    pub fn result(self: FoldScanner) FoldSim {
        return .{
            .foldable_bytes = self.foldable_bytes,
            .foldable_count = self.foldable_count,
            .triggered = self.foldable_bytes >= fold_min_bytes,
        };
    }
};

/// 按当前折叠规则模拟一段历史（输入按时间从旧到新）
pub fn simulateFold(history_oldest_first: []const ai.Message) FoldSim {
    var scanner = FoldScanner{};
    var i: usize = history_oldest_first.len;
    while (i > 0) {
        i -= 1;
        const m = history_oldest_first[i];
        if (scanner.feed(m.role, m.content, m.db_id != 0, m.folded) == .stop) break;
    }
    return scanner.result();
}

// ── 压缩 ──

/// checkpoint 伪消息的固定包装（发送与解析共用，避免格式漂移）
pub const checkpoint_tag = "<conversation-checkpoint>";
pub const checkpoint_desc = "（更早的对话已压缩，以下为摘要；需要细节时读取相关文件或询问用户）";

/// 是否为压缩 checkpoint 伪消息
pub fn isCheckpointMessage(m: ai.Message) bool {
    return std.mem.startsWith(u8, m.content, checkpoint_tag);
}

/// 构造 checkpoint 伪消息内容：固定包装 + 摘要正文
pub fn wrapCheckpoint(allocator: Allocator, summary: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        checkpoint_tag ++ "\n{s}\n{s}\n</conversation-checkpoint>",
        .{ checkpoint_desc, summary },
    );
}

/// 取出 checkpoint 伪消息里的摘要正文（去掉固定包装）。
/// 二次压缩时要把正文给模型继续合并——带上包装会让模型把标签抄进新摘要。
/// 反复剥离：历史数据里可能残留模型抄入的嵌套包装（2026-09 修复前的产物）。
pub fn checkpointBody(content: []const u8) []const u8 {
    var body = content;
    while (std.mem.startsWith(u8, body, checkpoint_tag ++ "\n")) {
        body = body[checkpoint_tag.len + 1 ..];
        if (std.mem.startsWith(u8, body, checkpoint_desc ++ "\n")) {
            body = body[checkpoint_desc.len + 1 ..];
        }
    }
    while (true) {
        if (std.mem.endsWith(u8, body, "\n</conversation-checkpoint>")) {
            body = body[0 .. body.len - "\n</conversation-checkpoint>".len];
        } else if (std.mem.endsWith(u8, body, "</conversation-checkpoint>")) {
            body = body[0 .. body.len - "</conversation-checkpoint>".len];
        } else break;
    }
    return body;
}

pub const CompactionRange = struct {
    /// 需要摘要的区间起点（含）
    summarize_start: usize,
    /// 保留区起点（含）：从这里到末尾原样发送
    retain_start: usize,
};

/// 选择压缩区间：system 与已有 checkpoint 永不进入摘要；
/// 保留区按字节预算从新到旧累计，起点对齐到不会被孤立的边界。
pub fn selectCompactionRange(history: []const ai.Message, keep_bytes: usize, count_reasoning: bool) ?CompactionRange {
    if (history.len == 0) return null;

    var summarize_start: usize = 0;
    if (std.mem.eql(u8, history[0].role, "system")) summarize_start = 1;
    if (summarize_start < history.len and isCheckpointMessage(history[summarize_start])) {
        summarize_start += 1;
    }
    if (summarize_start >= history.len) return null;

    var keep_start = history.len;
    var acc: usize = 0;
    while (keep_start > summarize_start) {
        const sz = messageRequestBytes(history[keep_start - 1], count_reasoning);
        if (acc > 0 and acc + sz > keep_bytes) break;
        acc += sz;
        keep_start -= 1;
    }
    if (keep_start <= summarize_start) return null;

    // 保留区起点不能是 tool 消息（其对应的调用若被摘要，会产生孤立引用）；
    // user / assistant 均可：assistant 带 tool_calls 时其结果紧随其后，协议自洽。
    // 允许 assistant 开头使「超长工具循环的当前回合」也能被部分压缩。
    var retain = keep_start;
    while (retain < history.len and std.mem.eql(u8, history[retain].role, "tool")) retain += 1;
    if (retain >= history.len) {
        // 极端情况（尾部全是 tool 结果）：退回对齐到最后一个 user
        var last_user: ?usize = null;
        var i = history.len;
        while (i > summarize_start) {
            i -= 1;
            if (std.mem.eql(u8, history[i].role, "user")) {
                last_user = i;
                break;
            }
        }
        retain = last_user orelse return null;
    }
    if (retain <= summarize_start) return null;
    return .{ .summarize_start = summarize_start, .retain_start = retain };
}

pub const compaction_system_prompt =
    "You are a context-compaction assistant for a coding agent. " ++
    "Do not continue the conversation. Do not respond to any questions in the conversation. " ++
    "Only output the summary. " ++
    "Tools are disabled and cannot actually run: attempting a tool call only outputs bare text, " ++
    "so never write bare tool-call or tool-result text; " ++
    "if you must reference tool-call or tool-result text, put it inside code blocks or inline code. " ++
    "Summarize the conversation segment so the work can be picked up later without the original messages. " ++
    "Keep concrete facts: the user's goal, what was done, key decisions, file paths, commands, errors and outcomes, and next steps. " ++
    "Write in the same language as the conversation. Use short markdown sections: " ++
    "## Goal / ## Progress / ## Key decisions / ## Files / ## Next steps.";

/// 摘要正文的"转录痕迹"标记（与 buildCompactionPayload 的转录格式一致）：
/// 模型偶尔把"写摘要"变成"继续干活"，输出工具调用/结果/思考痕迹（2026-10-13 事故）。
pub const summary_garbage_markers = [_][]const u8{
    "[tool call]",
    "[tool result",
    "<\u{ff5c}\u{ff5c}DSML\u{ff5c}\u{ff5c}",
    "[thinking]",
};

/// 摘要正文垃圾扫描器（**增量**；流式早停与落库前校验共用同一实现）。
/// 规则：**反引号成对视为代码**（简化 CommonMark：任一反引号在"代码/正常"间切换，
/// 单个 ` 与 ``` 均被成对反引号覆盖），代码态内不计；代码态外裸出现转录痕迹
/// ≥3 次 → 垃圾（单次/两次可能只是顺嘴提到）。只扫描正文；思考不扫描。
pub const SummaryScanner = struct {
    count: usize = 0,
    /// 行首命中的标记数（转录形态的强信号：`[tool call] name(` 出现在行首）
    strong_hits: usize = 0,
    in_code: bool = false,
    /// 最近字节环形（保留 ≥ 最长标记长度，供后缀匹配）
    hist: [64]u8 = undefined,
    hist_len: usize = 0,
    /// 累计喂入字节数（判断"命中是否在内容最开头"）
    total_bytes: usize = 0,

    pub fn feed(self: *SummaryScanner, delta: []const u8) void {
        for (delta) |b| {
            if (b == '`') {
                self.in_code = !self.in_code;
                self.histPush(b);
                continue;
            }
            self.histPush(b);
            if (self.in_code) continue;
            for (summary_garbage_markers) |mk| {
                if (self.hist_len >= mk.len and
                    std.mem.eql(u8, self.hist[self.hist_len - mk.len .. self.hist_len], mk))
                {
                    self.count += 1;
                    // 行首判定：命中起点前一个字节是换行（或命中在内容最开头）→ 强信号
                    const start = self.hist_len - mk.len;
                    const at_line_start = if (start == 0)
                        self.total_bytes == mk.len
                    else
                        self.hist[start - 1] == '\n';
                    if (at_line_start) self.strong_hits += 1;
                    break;
                }
            }
        }
    }

    pub fn isGarbage(self: *const SummaryScanner) bool {
        return self.count >= 3 or self.strong_hits >= 1;
    }

    fn histPush(self: *SummaryScanner, b: u8) void {
        if (self.hist_len == self.hist.len) {
            std.mem.copyForwards(u8, self.hist[0..32], self.hist[32..64]);
            self.hist_len = 32;
        }
        self.hist[self.hist_len] = b;
        self.hist_len += 1;
        self.total_bytes += 1;
    }
};

/// 摘要重试定向提示（追加到载荷**末尾**；前缀不变 → 提示缓存仍命中，只失效尾部一小段）：
/// 标记型垃圾 → 明示不要续写/不要输出工具调用裸文本；引用一律进代码块/反引号。
pub const compaction_retry_hint_garbage =
    "本次只输出摘要正文。不要继续对话、不要调用工具；工具已被禁用，调用只会输出裸文本，请务必避免这类裸文本；如需引用这类文本，请放进代码块或反引号内。";
/// 截断型（撞输出上限）→ 以正文为主、避免过度思考（思考同样吃上限；“务必简短”反而可能引发更久思考）。
pub const compaction_retry_hint_truncated =
    "请以输出摘要正文为主，避免过度思考；优先保留目标（Goal）、下一步（Next steps）与关键文件、命令。";

/// 落库前校验（整段）：扫描器喂全量后判定。
pub fn summaryLooksGarbage(content: []const u8) bool {
    var s = SummaryScanner{};
    s.feed(content);
    return s.isGarbage();
}

/// 按字符截断（UTF-8 边界安全；max_chars = 0 表示不截断）
pub fn truncateChars(s: []const u8, max_chars: usize) []const u8 {
    if (max_chars == 0) return s;
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len and count < max_chars) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + n > s.len) break;
        count += 1;
        i += n;
    }
    return s[0..i];
}

/// 摘要输入构建选项（第 2 层阶梯用）
pub const CompactionPayloadOptions = struct {
    /// 是否把思考作为文本喂给摘要器（默认开；超预算时降级为 false）
    include_thinking: bool = true,
    /// 工具结果截断上限（字符）
    tool_result_cap: usize = 2000,
    /// 工具参数截断上限（字符）
    tool_args_cap: usize = 500,
};

/// 摘要输入的保守字节预算：按"1 token ≥ 3 字节"的保守换算，并给摘要输出留余量。
/// 超预算 → 按阶梯降级（剥思考 → 加狠截断 → 丢最老）。
pub fn compactionPayloadBudgetBytes(window_tokens: usize) usize {
    const reserve = @min(window_tokens / 4, 16_384);
    const usable = window_tokens -| reserve;
    return usable * 3;
}

/// 构建摘要请求的对话文本（默认带思考；工具输出/参数按选项截断）
pub fn buildCompactionPayload(
    allocator: Allocator,
    history: []const ai.Message,
    range: CompactionRange,
    prev_summary: []const u8,
    opts: CompactionPayloadOptions,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    if (prev_summary.len > 0) {
        try out.writer.writeAll("## Earlier summary (already compacted; merge with the new conversation below)\n");
        try out.writer.writeAll(checkpointBody(prev_summary));
        try out.writer.writeAll("\n\n");
    }

    const CallName = struct { id: []const u8, name: []const u8 };
    var call_names = std.ArrayListUnmanaged(CallName).empty;
    defer call_names.deinit(allocator);
    for (history[range.summarize_start..range.retain_start]) |m| {
        if (m.tool_calls) |cs| {
            for (cs) |c| try call_names.append(allocator, .{ .id = c.id, .name = c.name });
        }
    }

    for (history[range.summarize_start..range.retain_start]) |m| {
        if (std.mem.eql(u8, m.role, "user")) {
            try out.writer.print("[user]\n{s}\n\n", .{m.content});
        } else if (std.mem.eql(u8, m.role, "assistant")) {
            if (opts.include_thinking and m.reasoning.len > 0) {
                try out.writer.print("[thinking]\n{s}\n", .{m.reasoning});
            }
            if (m.content.len > 0) try out.writer.print("[assistant]\n{s}\n", .{m.content});
            if (m.tool_calls) |cs| {
                for (cs) |c| {
                    try out.writer.print("[tool call] {s}({s})\n", .{ c.name, truncateChars(c.arguments, opts.tool_args_cap) });
                }
            }
            try out.writer.writeAll("\n");
        } else if (std.mem.eql(u8, m.role, "tool")) {
            var name: []const u8 = "tool";
            if (m.tool_call_id) |id| {
                for (call_names.items) |cn| {
                    if (std.mem.eql(u8, cn.id, id)) {
                        name = cn.name;
                        break;
                    }
                }
            }
            try out.writer.print("[tool result: {s}]\n{s}\n\n", .{ name, truncateChars(m.content, opts.tool_result_cap) });
        }
    }
    return out.toOwnedSlice();
}

/// 预算化构建结果（诊断/降级重试用）
pub const BudgetedPayload = struct {
    payload: []u8,
    /// 最终口径是否含思考
    include_thinking: bool,
    /// 是否用了加狠截断
    hard_truncated: bool,
    /// 从最老端丢掉的正文消息条数
    dropped_messages: usize,
};

/// 按预算构建摘要输入（第 2 层阶梯）：默认带思考 → 剥思考 → 工具加狠截断 →
/// 从最老端丢消息。上一轮摘要（prev_summary）始终保留；至少保留最后一条正文消息。
pub fn buildBudgetedCompactionPayload(
    allocator: Allocator,
    history: []const ai.Message,
    range: CompactionRange,
    prev_summary: []const u8,
    window_tokens: usize,
    initial_opts: CompactionPayloadOptions,
) !BudgetedPayload {
    const budget = compactionPayloadBudgetBytes(window_tokens);
    var opts = initial_opts;
    var start = range.summarize_start;
    var dropped: usize = 0;
    while (true) {
        const sub = CompactionRange{ .summarize_start = start, .retain_start = range.retain_start };
        const payload = try buildCompactionPayload(allocator, history, sub, prev_summary, opts);
        if (payload.len <= budget) {
            return .{
                .payload = payload,
                .include_thinking = opts.include_thinking,
                .hard_truncated = opts.tool_result_cap < 2000,
                .dropped_messages = dropped,
            };
        }
        const excess = payload.len - budget;
        allocator.free(payload);
        if (opts.include_thinking) {
            opts.include_thinking = false;
            continue;
        }
        if (opts.tool_result_cap >= 2000) {
            opts.tool_result_cap = 500;
            opts.tool_args_cap = 200;
            continue;
        }
        if (start + 1 < range.retain_start) {
            // 丢最老：按消息近似字节逐条丢（至少丢 1 条），至少保留最后一条
            var acc: usize = 0;
            while (start + 1 < range.retain_start and acc < excess) {
                acc += messageRequestBytes(history[start], false);
                start += 1;
                dropped += 1;
            }
            continue;
        }
        // 已到保底（只剩最后一条）仍超预算：尽力而为返回（预算极端小时才会发生）
        const payload2 = try buildCompactionPayload(allocator, history, sub, prev_summary, opts);
        return .{
            .payload = payload2,
            .include_thinking = opts.include_thinking,
            .hard_truncated = true,
            .dropped_messages = dropped,
        };
    }
}

test "摘要输入：默认带思考；超预算按阶梯降级（剥思考 → 加狠截断 → 丢最老）" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const calls = [_]ai.ToolCall{.{ .id = "c1", .name = "read", .arguments = utf8.repeat("x", 800) }};
    var msgs = std.ArrayListUnmanaged(ai.Message).empty;
    try msgs.append(a, .{ .role = "system", .content = "sys" });
    try msgs.append(a, .{ .role = "user", .content = utf8.repeat("U", 40) });
    try msgs.append(a, .{ .role = "assistant", .content = utf8.repeat("A", 40), .reasoning = utf8.repeat("R", 200), .tool_calls = &calls });
    try msgs.append(a, .{ .role = "tool", .content = utf8.repeat("T", 3000), .tool_call_id = "c1" });
    try msgs.append(a, .{ .role = "user", .content = utf8.repeat("V", 40) });
    try msgs.append(a, .{ .role = "assistant", .content = utf8.repeat("B", 40), .reasoning = utf8.repeat("S", 200) });

    const range = CompactionRange{ .summarize_start = 1, .retain_start = 6 };
    const prev = "PSPSPSPSPSPSPSPSPSPS";

    // 三个档位的底价：带思考 / 剥思考 / 加狠截断（量出实际字节数，再反推窗口）
    const full = try buildCompactionPayload(a, msgs.items, range, prev, .{});
    const stripped = try buildCompactionPayload(a, msgs.items, range, prev, .{ .include_thinking = false });
    const hard = try buildCompactionPayload(a, msgs.items, range, prev, .{ .include_thinking = false, .tool_result_cap = 500, .tool_args_cap = 200 });
    try t.expect(full.len > stripped.len + 200);
    try t.expect(stripped.len > hard.len + 200);
    try t.expect(std.mem.indexOf(u8, full, "[thinking]") != null);
    try t.expect(std.mem.indexOf(u8, full, utf8.repeat("R", 200)) != null);
    try t.expect(std.mem.indexOf(u8, stripped, "[thinking]") == null);

    const windowFor = struct {
        fn f(target: usize) usize {
            var w: usize = 8;
            while (compactionPayloadBudgetBytes(w) < target) w += 1;
            return w;
        }
    }.f;

    // 档位 0：大窗口 → 带思考（上一轮摘要始终在）
    {
        const built = try buildBudgetedCompactionPayload(a, msgs.items, range, prev, 1_000_000, .{});
        try t.expect(built.include_thinking);
        try t.expect(std.mem.indexOf(u8, built.payload, utf8.repeat("R", 200)) != null);
        try t.expect(std.mem.indexOf(u8, built.payload, prev) != null);
    }
    // 档位 1：预算刚好装下“剥思考”版 → 剥思考
    {
        const w = windowFor(stripped.len + 8);
        try t.expect(compactionPayloadBudgetBytes(w) < full.len);
        const built = try buildBudgetedCompactionPayload(a, msgs.items, range, prev, w, .{});
        try t.expect(!built.include_thinking);
        try t.expect(!built.hard_truncated);
        try t.expectEqual(@as(usize, 0), built.dropped_messages);
    }
    // 档位 2：预算只装得下“加狠截断”版 → 剥思考 + 加狠截断
    {
        const w = windowFor(hard.len + 8);
        try t.expect(compactionPayloadBudgetBytes(w) < stripped.len);
        const built = try buildBudgetedCompactionPayload(a, msgs.items, range, prev, w, .{});
        try t.expect(!built.include_thinking);
        try t.expect(built.hard_truncated);
        try t.expectEqual(@as(usize, 0), built.dropped_messages);
    }
    // 档位 3：预算不足 → 从最老端丢消息（上一轮摘要与最新消息保留）
    {
        const w = windowFor(hard.len / 2 + 8);
        const built = try buildBudgetedCompactionPayload(a, msgs.items, range, prev, w, .{});
        try t.expect(built.dropped_messages > 0);
        try t.expect(std.mem.indexOf(u8, built.payload, utf8.repeat("U", 40)) == null);
        try t.expect(std.mem.indexOf(u8, built.payload, utf8.repeat("B", 40)) != null);
        try t.expect(std.mem.indexOf(u8, built.payload, prev) != null);
    }
    // 档位 4：极端小窗口 → 保底（只剩最后一条），尽力而为返回
    {
        const built = try buildBudgetedCompactionPayload(a, msgs.items, range, prev, 8, .{});
        try t.expectEqual(@as(usize, 4), built.dropped_messages);
        try t.expect(std.mem.indexOf(u8, built.payload, utf8.repeat("B", 40)) != null);
        try t.expect(std.mem.indexOf(u8, built.payload, prev) != null);
    }
}

test "压缩提示词：禁止继续 + 只输出摘要 + 工具禁用（对齐 pi/opencode；无 continue working 字样）" {
    try std.testing.expect(std.mem.indexOf(u8, compaction_system_prompt, "Do not continue the conversation") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_system_prompt, "Only output the summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_system_prompt, "Tools are disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_system_prompt, "bare text") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_system_prompt, "continue working") == null);
}

test "摘要垃圾校验：续写垃圾拒绝 / 引用式摘要通过 / 阈值 ≥3 次" {
    // 真实事故样本（Sawdust id=18）：续写 + 伪造工具调用/结果 → 垃圾
    const garbage = "继续大任务。先核对 renderSegment 替换后的当前状态：\n" ++
        "[tool call] read({\"path\":\"src/audio.zig\"})\n" ++
        "[tool call] bash({...})\n" ++
        "[tool result: read]\n" ++
        "[工具输出已折叠：read 输出 4283 字符]\n" ++
        "[tool result: bash]\n";
    try std.testing.expect(summaryLooksGarbage(garbage));
    // 老事故样本（id=12）：DSML 工具调用特殊标记裸出现 → 垃圾
    try std.testing.expect(summaryLooksGarbage("<\u{ff5c}\u{ff5c}DSML\u{ff5c}\u{ff5c} calls>\n<\u{ff5c}\u{ff5c}DSML\u{ff5c}\u{ff5c} invoke name=\"bash\">\n<\u{ff5c}\u{ff5c}DSML\u{ff5c}\u{ff5c} parameter name=\"command\">x"));
    // 思考痕迹裸出现 3 次 → 垃圾
    try std.testing.expect(summaryLooksGarbage("[thinking] 一 [thinking] 二 [thinking] 三"));
    // 引用式摘要（真实检查点形态）：标记都在代码块/行内代码里 → 通过
    const quoting = "## 核心事故\n\n摘要正文出现 `[tool call]` / `[tool result` 即判垃圾：\n\n" ++
        "```\n继续大任务。\n[tool call] read(...)\n[tool result: read]\n[tool call] bash(...)\n```\n\n" ++
        "即把转录当成了续写模板。\n";
    try std.testing.expect(!summaryLooksGarbage(quoting));
    // 阈值：裸出现 2 次仍通过；3 次才判垃圾
    try std.testing.expect(!summaryLooksGarbage("正文提到 [tool call] 一次、[tool call] 两次"));
    // 正常摘要
    try std.testing.expect(!summaryLooksGarbage("## Goal\n修复提示词。\n## Next steps\n重新压缩。"));
}

test "摘要重试提示：覆盖两个失败类型（只输出摘要 / 代码块口子 / 不过度思考）" {
    try std.testing.expect(std.mem.indexOf(u8, compaction_retry_hint_garbage, "只输出摘要正文") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_retry_hint_garbage, "不要继续对话") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_retry_hint_garbage, "代码块或反引号") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_retry_hint_truncated, "过度思考") != null);
    try std.testing.expect(std.mem.indexOf(u8, compaction_retry_hint_truncated, "Next steps") != null);
}

test "摘要垃圾扫描：分块喂入与整段一致（跨块半个标记 / 代码态跨界）" {
    // 代码内引用不计；代码外 3 个裸标记 → 垃圾
    const sample = "引言 `引用 [tool call]` 与 ```\n块内 [tool result: x]\n``` 之外 [tool call] [tool call] [tool call]";
    try std.testing.expect(summaryLooksGarbage(sample));
    // 逐字节喂
    var s = SummaryScanner{};
    for (sample) |b| s.feed(&[_]u8{b});
    try std.testing.expect(s.isGarbage());
    // 乱切块（每 3 字节，制造跨块半个标记）
    var s2 = SummaryScanner{};
    var i: usize = 0;
    while (i < sample.len) : (i += 3) s2.feed(sample[i..@min(i + 3, sample.len)]);
    try std.testing.expect(s2.isGarbage());
    // 2 个裸标记 + 1 个块内标记 → 通过（块内不计）
    const sample2 = "正文 [tool call] 一次 [tool call] 两次，示例：```[tool call] read()```";
    var s3 = SummaryScanner{};
    for (sample2) |b| s3.feed(&[_]u8{b});
    try std.testing.expect(!s3.isGarbage());
    // 标记跨块拆开仍能命中（"[tool " + "call]" ×3）
    var s4 = SummaryScanner{};
    s4.feed("[tool ");
    s4.feed("call][tool ");
    s4.feed("call][tool call]");
    try std.testing.expect(s4.isGarbage());
}

test "摘要垃圾扫描：行首标记 1 次即垃圾（行中/代码内不算）" {
    try std.testing.expect(summaryLooksGarbage("[tool call] read(x)")); // 内容开头
    try std.testing.expect(summaryLooksGarbage("继续。\n[tool call] read(x)")); // 换行后行首
    try std.testing.expect(!summaryLooksGarbage("正文里出现 [tool call] 的情况")); // 行中
    try std.testing.expect(!summaryLooksGarbage("- [tool call] 行")); // 行首是"- "
    try std.testing.expect(!summaryLooksGarbage("```\n[tool call] read(x)\n```")); // 代码块内
}

// ── 测试 ──

const testing = std.testing;

/// 运行期构造大块测试数据（0.17 编译期大常量会拖死编译甚至 OOM，见 utf8.repeat 注释）
fn fillBuf(a: std.mem.Allocator, pattern: []const u8, n: usize) ![]u8 {
    const buf = try a.alloc(u8, pattern.len * n);
    var i: usize = 0;
    while (i < buf.len) : (i += pattern.len) @memcpy(buf[i..][0..pattern.len], pattern);
    return buf;
}

test "token 估算与折叠模拟" {
    const ba = testing.allocator;
    const b_a30 = try fillBuf(ba, "a", 30_000);
    defer ba.free(b_a30);
    const b_b30 = try fillBuf(ba, "b", 30_000);
    defer ba.free(b_b30);
    const b_a100 = try fillBuf(ba, "a", 100_000);
    defer ba.free(b_a100);
    const b_b100 = try fillBuf(ba, "b", 100_000);
    defer ba.free(b_b100);
    const b_c100 = try fillBuf(ba, "c", 100_000);
    defer ba.free(b_c100);
    const b_d10 = try fillBuf(ba, "d", 10_000);
    defer ba.free(b_d10);
    const b_e10 = try fillBuf(ba, "e", 10_000);
    defer ba.free(b_e10);
    const b_old = try fillBuf(ba, "old", 100_000);
    defer ba.free(b_old);
    const b_x512 = try fillBuf(ba, "x", 512);
    defer ba.free(b_x512);
    const b_a10 = try fillBuf(ba, "a", 10_000);
    defer ba.free(b_a10);
    const b_b300 = try fillBuf(ba, "b", 300_000);
    defer ba.free(b_b300);
    const b_c300 = try fillBuf(ba, "c", 300_000);
    defer ba.free(b_c300);
    try testing.expectEqual(@as(usize, 0), estimateTokens(0));
    try testing.expectEqual(@as(usize, 1), estimateTokens(4));
    try testing.expectEqual(@as(usize, 2), estimateTokens(5));

    // 两个 30KB 在最近回合 + 保护窗口内 → 不折叠
    var small = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = b_a30, .db_id = 1 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = b_b30, .db_id = 2 },
    };
    const sim_small = simulateFold(&small);
    try testing.expectEqual(@as(usize, 0), sim_small.foldable_count);
    try testing.expect(!sim_small.triggered);

    // 3 条 100KB + 末尾两个空回合：最近 2 回合受位置保护，其余窗口保护最新 2 条，最旧 1 条可折
    var big = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = b_a100, .db_id = 1 },
        .{ .role = "tool", .content = b_b100, .db_id = 2 },
        .{ .role = "tool", .content = b_c100, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = b_d10, .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = b_e10, .db_id = 5 },
    };
    const sim_big = simulateFold(&big);
    try testing.expectEqual(@as(usize, 1), sim_big.foldable_count);
    try testing.expectEqual(@as(usize, 100_000), sim_big.foldable_bytes);
    try testing.expect(sim_big.triggered);

    // 已折叠（folded 标记）是扫描边界：更早的大输出不再计入（旧地址早已处理过）
    var stubs = [_]ai.Message{
        .{ .role = "tool", .content = b_old, .db_id = 9 },
        .{ .role = "tool", .content = "stub 文本", .db_id = 8, .folded = true },
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = b_a100, .db_id = 1 },
        .{ .role = "tool", .content = b_b100, .db_id = 2 },
        .{ .role = "tool", .content = b_c100, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = b_d10, .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = b_e10, .db_id = 5 },
    };
    const sim_stubs = simulateFold(&stubs);
    try testing.expectEqual(@as(usize, 1), sim_stubs.foldable_count);
    try testing.expectEqual(@as(usize, 100_000), sim_stubs.foldable_bytes);

    // 小输出（< 1KB）不折叠、也不占用保护窗口：最旧的 100KB 仍在窗口内 → 无可折叠
    var tiny = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = b_x512, .db_id = 1 },
        .{ .role = "tool", .content = b_a100, .db_id = 2 },
        .{ .role = "tool", .content = b_b100, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = utf8.repeat("c", 10_000), .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = b_d10, .db_id = 5 },
    };
    const sim_tiny = simulateFold(&tiny);
    try testing.expectEqual(@as(usize, 0), sim_tiny.foldable_count);
    try testing.expect(!sim_tiny.triggered);

    // 未落库（db_id = 0）不折叠：重启后无法复现相同前缀
    var unsaved = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = b_a100 },
        .{ .role = "tool", .content = b_b100, .db_id = 2 },
        .{ .role = "tool", .content = b_c100, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = b_d10, .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = b_e10, .db_id = 5 },
    };
    try testing.expect(simulateFold(&unsaved).foldable_count == 0);

    // 最近两个回合内无论多大都不折（位置保护）
    var recent = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = b_a10, .db_id = 1 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = b_b300, .db_id = 2 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = b_c300, .db_id = 3 },
    };
    const sim_recent = simulateFold(&recent);
    try testing.expectEqual(@as(usize, 0), sim_recent.foldable_count);
    try testing.expect(!sim_recent.triggered);
}

test "压缩区间选择（跳过已有 checkpoint，保留边界不产生孤立引用）" {
    const msgs = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "u1" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "tool", .content = "t1", .tool_call_id = "c1" },
        .{ .role = "user", .content = "u2" },
        .{ .role = "assistant", .content = "a2" },
    };
    // 保留窗口极小 → 收下 a2 后 u2 超预算，keep_start 落在 assistant（不再强推回 user）
    const r = selectCompactionRange(&msgs, 1, false).?;
    try testing.expectEqual(@as(usize, 1), r.summarize_start);
    try testing.expectEqual(@as(usize, 5), r.retain_start);

    // 窗口很大 → 无需压缩
    try testing.expect(selectCompactionRange(&msgs, 1 << 20, false) == null);

    // 已有 checkpoint：摘要从 checkpoint 之后开始
    const with_cp = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "<conversation-checkpoint>old</conversation-checkpoint>" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "tool", .content = "t1", .tool_call_id = "c1" },
        .{ .role = "user", .content = "u2" },
    };
    const r2 = selectCompactionRange(&with_cp, 1, false).?;
    try testing.expectEqual(@as(usize, 2), r2.summarize_start);
    try testing.expectEqual(@as(usize, 4), r2.retain_start);
}

test "压缩区间选择：保留区可从 assistant 开始（当前回合可被部分压缩）" {
    // 超长工具循环：回合内只有开头一个 user，其余是 assistant/tool 交替
    // 单条字节：无调用助手/工具=4 左右，带调用的 assistant = 4 + (2 + 32) = 38
    const turn = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "u0" },
        .{ .role = "assistant", .content = "a0" },
        .{ .role = "user", .content = "u1" },
        .{ .role = "assistant", .content = "aaaa", .tool_calls = &.{.{ .id = "c1", .name = "read", .arguments = "{}" }} },
        .{ .role = "tool", .content = "tttt", .tool_call_id = "c1" },
        .{ .role = "assistant", .content = "bbbb", .tool_calls = &.{.{ .id = "c2", .name = "read", .arguments = "{}" }} },
        .{ .role = "tool", .content = "tttt", .tool_call_id = "c2" },
    };
    // 预算 42：收下 t2(4)+a2(38)，再往前 t1 超预算 → keep_start 落在 assistant（index 6）
    const r = selectCompactionRange(&turn, 42, false).?;
    try testing.expectEqual(@as(usize, 1), r.summarize_start);
    try testing.expectEqual(@as(usize, 6), r.retain_start); // 当前回合前半段(u1,a1,t1)进入摘要

    // keep_start 落在 tool 上时向前跳过（不能以 tool 开头），落到其后的 assistant
    // 预算 50：收下 t2(4)+a2(38)+t1(4)=46，再往前 a1 超预算 → keep_start=5（tool t1）→ 跳到 6
    const r2 = selectCompactionRange(&turn, 50, false).?;
    try testing.expectEqual(@as(usize, 6), r2.retain_start);

    // 尾部全是 tool（异常历史）：退回对齐到最后一个 user，保证不产生孤立引用
    const tails = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "u0" },
        .{ .role = "assistant", .content = "a0" },
        .{ .role = "user", .content = "u1" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "tool", .content = "t1", .tool_call_id = "c1" },
        .{ .role = "tool", .content = "t2", .tool_call_id = "c2" },
    };
    // 预算 3：收下 t2(2)，t1(2) 超预算 → keep_start=6（tool）→ 跳过剩余 tool → 退到 u1
    const r3 = selectCompactionRange(&tails, 3, false).?;
    try testing.expectEqual(@as(usize, 3), r3.retain_start);
}

test "请求字节估算：思考按需计入（能力表 interleaved 口径）" {
    const msgs = [_]ai.Message{
        .{ .role = "user", .content = "u" },
        .{ .role = "assistant", .content = "a", .reasoning = "rrrrrr" },
        .{ .role = "tool", .content = "t", .tool_call_id = "c1" },
    };
    // 不计入：只算正文（user 1 + assistant 1 + tool 1）
    try testing.expectEqual(@as(usize, 3), historyRequestBytesSlice(&msgs, false));
    // 计入：assistant 的 reasoning 也进请求（6 字节）；非 assistant 无此字段
    try testing.expectEqual(@as(usize, 9), historyRequestBytesSlice(&msgs, true));

    // 保留区选择同口径：思考重时单条字节更大、预算更早打满（保留区更小）
    const tail = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "u0" },
        .{ .role = "assistant", .content = "a1", .reasoning = utf8.repeat("x", 60) },
    };
    // 预算 10：不计 reasoning → 保留窗口吃掉全部（无需压缩）；
    // 计入后 a1 单条即超预算 → 有可压缩内容（保留区不再吞掉整段）
    try testing.expect(selectCompactionRange(&tail, 10, false) == null);
    try testing.expect(selectCompactionRange(&tail, 10, true) != null);
}

test "上下文溢出错误识别（P2 自愈用）" {
    try testing.expect(isContextOverflowText("This model's maximum context length is 131072 tokens."));
    try testing.expect(isContextOverflowText("Prompt is too long: 213462 tokens > 200000 maximum"));
    try testing.expect(isContextOverflowText("{\"error\":{\"code\":\"context_length_exceeded\"}}"));
    try testing.expect(isContextOverflowText("the request exceeds the available context size, try increasing it"));
    try testing.expect(isContextOverflowText("prompt too long; exceeded max context length"));
    // 反例：限流/瞬时故障（含“too many tokens”的限流误报）与无关文本
    try testing.expect(!isContextOverflowText("Rate limit reached for requests"));
    try testing.expect(!isContextOverflowText("ThrottlingException: Too many tokens, please wait before trying again."));
    try testing.expect(!isContextOverflowText("Internal server error"));
    try testing.expect(!isContextOverflowText(""));
}

test "checkpointBody：剥离固定包装（二次压缩合并时避免标签污染）" {
    const wrapped = "<conversation-checkpoint>\n" ++ checkpoint_desc ++ "\n## Goal\n内容\n</conversation-checkpoint>";
    try testing.expectEqualStrings("## Goal\n内容", checkpointBody(wrapped));
    // 无包装原样返回；空摘要剥离后为空
    try testing.expectEqualStrings("plain", checkpointBody("plain"));
    try testing.expectEqualStrings("", checkpointBody("<conversation-checkpoint>\n" ++ checkpoint_desc ++ "\n\n</conversation-checkpoint>"));
    // 嵌套包装（历史遗留：模型把包装抄进了摘要正文）→ 全部剥离
    const nested = "<conversation-checkpoint>\n" ++ checkpoint_desc ++ "\n" ++
        "<conversation-checkpoint>\n" ++ checkpoint_desc ++ "\n## Goal\n内容\n</conversation-checkpoint>\n</conversation-checkpoint>";
    try testing.expectEqualStrings("## Goal\n内容", checkpointBody(nested));
    // wrapCheckpoint 与 checkpointBody 互逆
    const w = try wrapCheckpoint(testing.allocator, "## X\ny");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("## X\ny", checkpointBody(w));
}

test "按字符截断：UTF-8 边界安全" {
    try testing.expectEqualStrings("abc", truncateChars("abcdef", 3));
    try testing.expectEqualStrings("abcdef", truncateChars("abcdef", 0)); // 0 = 不截断
    try testing.expectEqualStrings("中", truncateChars("中文", 1));
    try testing.expectEqualStrings("中文", truncateChars("中文", 2));
    try testing.expectEqualStrings("中文", truncateChars("中文", 99));
}
