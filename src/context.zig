//! 上下文管理纯计算：token 估算、工具输出折叠模拟、压缩区间选择与摘要输入构建。
//! 不依赖 AppState / UI，便于单测与复用。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ai = @import("ai.zig");
const tools_mod = @import("tools.zig");

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

/// 单条消息进入请求的近似字节数（正文 + tool_calls 参数）
pub fn messageRequestBytes(m: ai.Message) usize {
    var n: usize = m.content.len;
    if (m.tool_calls) |cs| {
        for (cs) |c| n += c.arguments.len + 32;
    }
    return n;
}

/// 一段历史的近似请求字节数
pub fn historyRequestBytesSlice(history: []const ai.Message) usize {
    var bytes: usize = 0;
    for (history) |m| bytes += messageRequestBytes(m);
    return bytes;
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
/// 2. 遇到已折叠 stub 即停（更早的内容早已处理过，无需继续扫描）
/// 3. 单条小于 fold_min_output_bytes 不折
/// 4. 最近 fold_protect_bytes 字节（从新到旧累计）受保护，更早的才算候选
pub const FoldScanner = struct {
    protected_bytes: usize = 0,
    user_turns: usize = 0,
    foldable_bytes: usize = 0,
    foldable_count: usize = 0,

    pub const Action = enum { skip, stop, candidate };

    /// persistable：工具结果是否已落库（未落库的不能折叠，否则重启后请求前缀不一致）
    pub fn feed(self: *FoldScanner, role: []const u8, content: []const u8, persistable: bool) Action {
        if (std.mem.eql(u8, role, "user")) {
            self.user_turns += 1;
            return .skip;
        }
        if (!std.mem.eql(u8, role, "tool")) return .skip;
        if (content.len == 0) return .skip;
        if (self.user_turns < fold_protect_turns) return .skip;
        if (std.mem.startsWith(u8, content, fold_marker)) return .stop;
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
        if (scanner.feed(m.role, m.content, m.db_id != 0) == .stop) break;
    }
    return scanner.result();
}

// ── 压缩 ──

/// 是否为压缩 checkpoint 伪消息
pub fn isCheckpointMessage(m: ai.Message) bool {
    return std.mem.startsWith(u8, m.content, "<conversation-checkpoint>");
}

pub const CompactionRange = struct {
    /// 需要摘要的区间起点（含）
    summarize_start: usize,
    /// 保留区起点（含）：从这里到末尾原样发送
    retain_start: usize,
};

/// 选择压缩区间：system 与已有 checkpoint 永不进入摘要；
/// 保留区按字节预算从新到旧累计，并对齐到 user 消息边界（避免孤立 tool 引用）。
pub fn selectCompactionRange(history: []const ai.Message, keep_bytes: usize) ?CompactionRange {
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
        const sz = messageRequestBytes(history[keep_start - 1]);
        if (acc > 0 and acc + sz > keep_bytes) break;
        acc += sz;
        keep_start -= 1;
    }
    if (keep_start <= summarize_start) return null;

    // 保留区必须以 user 开头：向后找到最近的 user；找不到则退到最后一个 user
    var retain = keep_start;
    while (retain < history.len and !std.mem.eql(u8, history[retain].role, "user")) retain += 1;
    if (retain >= history.len) {
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
    "Summarize the conversation segment so the agent can continue working without the original messages. " ++
    "Keep concrete facts: the user's goal, what was done, key decisions, file paths, commands, errors and outcomes, and next steps. " ++
    "Write in the same language as the conversation. Use short markdown sections: " ++
    "## Goal / ## Progress / ## Key decisions / ## Files / ## Next steps.";

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

/// 构建摘要请求的对话文本：工具输出截断到 2000 字符
pub fn buildCompactionPayload(
    allocator: Allocator,
    history: []const ai.Message,
    range: CompactionRange,
    prev_summary: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    if (prev_summary.len > 0) {
        try out.writer.writeAll("## Earlier summary (already compacted; merge with the new conversation below)\n");
        try out.writer.writeAll(prev_summary);
        try out.writer.writeAll("\n\n");
    }

    const CallName = struct { id: []const u8, name: []const u8 };
    var call_names = std.ArrayListUnmanaged(CallName){ .items = &.{}, .capacity = 0 };
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
            if (m.content.len > 0) try out.writer.print("[assistant]\n{s}\n", .{m.content});
            if (m.tool_calls) |cs| {
                for (cs) |c| {
                    try out.writer.print("[tool call] {s}({s})\n", .{ c.name, truncateChars(c.arguments, 500) });
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
            try out.writer.print("[tool result: {s}]\n{s}\n\n", .{ name, truncateChars(m.content, 2000) });
        }
    }
    return out.toOwnedSlice();
}

// ── 测试 ──

const testing = std.testing;

test "token 估算与折叠模拟" {
    try testing.expectEqual(@as(usize, 0), estimateTokens(0));
    try testing.expectEqual(@as(usize, 1), estimateTokens(4));
    try testing.expectEqual(@as(usize, 2), estimateTokens(5));

    // 两个 30KB 在最近回合 + 保护窗口内 → 不折叠
    var small = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = "a" ** 30_000, .db_id = 1 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = "b" ** 30_000, .db_id = 2 },
    };
    const sim_small = simulateFold(&small);
    try testing.expectEqual(@as(usize, 0), sim_small.foldable_count);
    try testing.expect(!sim_small.triggered);

    // 3 条 100KB + 末尾两个空回合：最近 2 回合受位置保护，其余窗口保护最新 2 条，最旧 1 条可折
    var big = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = "a" ** 100_000, .db_id = 1 },
        .{ .role = "tool", .content = "b" ** 100_000, .db_id = 2 },
        .{ .role = "tool", .content = "c" ** 100_000, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = "d" ** 10_000, .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = "e" ** 10_000, .db_id = 5 },
    };
    const sim_big = simulateFold(&big);
    try testing.expectEqual(@as(usize, 1), sim_big.foldable_count);
    try testing.expectEqual(@as(usize, 100_000), sim_big.foldable_bytes);
    try testing.expect(sim_big.triggered);

    // 已折叠 stub 是扫描边界：更早的大输出不再计入（旧地址早已处理过）
    var stubs = [_]ai.Message{
        .{ .role = "tool", .content = "old" ** 100_000, .db_id = 9 },
        .{ .role = "tool", .content = fold_marker ++ "x]", .db_id = 8 },
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = "a" ** 100_000, .db_id = 1 },
        .{ .role = "tool", .content = "b" ** 100_000, .db_id = 2 },
        .{ .role = "tool", .content = "c" ** 100_000, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = "d" ** 10_000, .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = "e" ** 10_000, .db_id = 5 },
    };
    const sim_stubs = simulateFold(&stubs);
    try testing.expectEqual(@as(usize, 1), sim_stubs.foldable_count);
    try testing.expectEqual(@as(usize, 100_000), sim_stubs.foldable_bytes);

    // 小输出（< 1KB）不折叠、也不占用保护窗口：最旧的 100KB 仍在窗口内 → 无可折叠
    var tiny = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = "x" ** 512, .db_id = 1 },
        .{ .role = "tool", .content = "a" ** 100_000, .db_id = 2 },
        .{ .role = "tool", .content = "b" ** 100_000, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = "c" ** 10_000, .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = "d" ** 10_000, .db_id = 5 },
    };
    const sim_tiny = simulateFold(&tiny);
    try testing.expectEqual(@as(usize, 0), sim_tiny.foldable_count);
    try testing.expect(!sim_tiny.triggered);

    // 未落库（db_id = 0）不折叠：重启后无法复现相同前缀
    var unsaved = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = "a" ** 100_000 },
        .{ .role = "tool", .content = "b" ** 100_000, .db_id = 2 },
        .{ .role = "tool", .content = "c" ** 100_000, .db_id = 3 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = "d" ** 10_000, .db_id = 4 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = "e" ** 10_000, .db_id = 5 },
    };
    try testing.expect(simulateFold(&unsaved).foldable_count == 0);

    // 最近两个回合内无论多大都不折（位置保护）
    var recent = [_]ai.Message{
        .{ .role = "user", .content = "u1" },
        .{ .role = "tool", .content = "a" ** 10_000, .db_id = 1 },
        .{ .role = "user", .content = "u2" },
        .{ .role = "tool", .content = "b" ** 300_000, .db_id = 2 },
        .{ .role = "user", .content = "u3" },
        .{ .role = "tool", .content = "c" ** 300_000, .db_id = 3 },
    };
    const sim_recent = simulateFold(&recent);
    try testing.expectEqual(@as(usize, 0), sim_recent.foldable_count);
    try testing.expect(!sim_recent.triggered);
}

test "压缩区间选择（对齐 user 边界，跳过已有 checkpoint）" {
    const msgs = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "u1" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "tool", .content = "t1", .tool_call_id = "c1" },
        .{ .role = "user", .content = "u2" },
        .{ .role = "assistant", .content = "a2" },
    };
    // 保留窗口极小 → 保留区对齐到最近的 user
    const r = selectCompactionRange(&msgs, 1).?;
    try testing.expectEqual(@as(usize, 1), r.summarize_start);
    try testing.expectEqual(@as(usize, 4), r.retain_start);

    // 窗口很大 → 无需压缩
    try testing.expect(selectCompactionRange(&msgs, 1 << 20) == null);

    // 已有 checkpoint：摘要从 checkpoint 之后开始
    const with_cp = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "<conversation-checkpoint>old</conversation-checkpoint>" },
        .{ .role = "assistant", .content = "a1" },
        .{ .role = "tool", .content = "t1", .tool_call_id = "c1" },
        .{ .role = "user", .content = "u2" },
    };
    const r2 = selectCompactionRange(&with_cp, 1).?;
    try testing.expectEqual(@as(usize, 2), r2.summarize_start);
    try testing.expectEqual(@as(usize, 4), r2.retain_start);
}

test "按字符截断：UTF-8 边界安全" {
    try testing.expectEqualStrings("abc", truncateChars("abcdef", 3));
    try testing.expectEqualStrings("abcdef", truncateChars("abcdef", 0)); // 0 = 不截断
    try testing.expectEqualStrings("中", truncateChars("中文", 1));
    try testing.expectEqualStrings("中文", truncateChars("中文", 2));
    try testing.expectEqualStrings("中文", truncateChars("中文", 99));
}
