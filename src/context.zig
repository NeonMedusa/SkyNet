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

/// 保护最近约 40k tokens 的工具输出；可折叠量达到约 20k tokens 才批量折叠
pub const fold_protect_bytes: usize = 160 * 1024;
pub const fold_min_bytes: usize = 80 * 1024;
/// 已折叠 stub 的识别前缀
pub const fold_marker = "[工具输出已折叠";

/// 可折叠的工具消息：工具结果、有内容、已落库、尚未折叠
pub fn isFoldableMessage(m: ai.Message) bool {
    return std.mem.eql(u8, m.role, "tool") and m.content.len > 0 and
        m.db_id != 0 and !std.mem.startsWith(u8, m.content, fold_marker);
}

pub const FoldSim = struct {
    foldable_bytes: usize = 0,
    foldable_count: usize = 0,
    triggered: bool = false,
};

/// 按当前折叠规则模拟（输入按时间从旧到新；空内容与已折叠 stub 跳过）
pub fn simulateFold(contents_oldest_first: []const []const u8) FoldSim {
    var sim = FoldSim{};
    var protected_bytes: usize = 0;
    var i: usize = contents_oldest_first.len;
    while (i > 0) {
        i -= 1;
        const c = contents_oldest_first[i];
        if (c.len == 0 or std.mem.startsWith(u8, c, fold_marker)) continue;
        if (protected_bytes < fold_protect_bytes) {
            protected_bytes += c.len;
        } else {
            sim.foldable_bytes += c.len;
            sim.foldable_count += 1;
        }
    }
    sim.triggered = sim.foldable_bytes >= fold_min_bytes;
    return sim;
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

/// 构建摘要请求的对话文本：工具输出截断到 2000 字符（pi 的做法）
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

    // 两个 30KB：都在保护窗口（160KB）内 → 不折叠
    const small = [_][]const u8{ "a" ** 30_000, "b" ** 30_000 };
    const sim_small = simulateFold(&small);
    try testing.expectEqual(@as(usize, 0), sim_small.foldable_count);
    try testing.expect(!sim_small.triggered);

    // 四个 100KB（从旧到新）：最新两个占满保护窗口，最旧两个可折（200KB ≥ 80KB 阈值）
    const big = [_][]const u8{ "a" ** 100_000, "b" ** 100_000, "c" ** 100_000, "d" ** 100_000 };
    const sim_big = simulateFold(&big);
    try testing.expectEqual(@as(usize, 2), sim_big.foldable_count);
    try testing.expectEqual(@as(usize, 200_000), sim_big.foldable_bytes);
    try testing.expect(sim_big.triggered);

    // 已折叠的 stub 不重复计入
    const stubs = [_][]const u8{ fold_marker ++ "x]", "b" ** 100_000, "c" ** 100_000, "d" ** 100_000 };
    const sim_stubs = simulateFold(&stubs);
    try testing.expectEqual(@as(usize, 1), sim_stubs.foldable_count);
    try testing.expectEqual(@as(usize, 100_000), sim_stubs.foldable_bytes);
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
