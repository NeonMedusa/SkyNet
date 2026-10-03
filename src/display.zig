//! 工具/消息的"显示文本"纯函数（无 AppState 依赖）。
//!
//! 从 main.zig 抽出：① 迁移（db.zig 回填 disp_header）与运行时共用同一套生成逻辑，
//! 避免两边格式漂移；② 未来其他模块（CLI/导出）复用。
//!
//! 约定：所有返回的文本都分配在传入的 arena，调用方负责生命周期。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 工具块渲染类型：shell 输出 / 行号 diff
pub const ToolBlockKind = enum { shell, diff };

/// 工具 → 块渲染类型（仅 bash/edit 使用块渲染）
pub fn toolBlockKind(name: []const u8) ?ToolBlockKind {
    if (std.mem.eql(u8, name, "bash")) return .shell;
    if (std.mem.eql(u8, name, "edit")) return .diff;
    return null;
}

/// 从参数 JSON 中取字符串字段
pub fn extractJsonString(arena: Allocator, args_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// 从参数 JSON 中取整数字段
pub fn extractJsonInt(arena: Allocator, args_json: []const u8, field: []const u8) ?i64 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// 从参数 JSON 中取布尔字段
pub fn extractJsonBool(arena: Allocator, args_json: []const u8, field: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return false;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return false,
    };
    const v = obj.get(field) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

pub fn formatBytes(buf: []u8, len: usize) []const u8 {
    if (len < 1024) return std.fmt.bufPrint(buf, "{d}B", .{len}) catch "?";
    const kb100 = (len * 10) / 1024;
    return std.fmt.bufPrint(buf, "{d}.{d}KB", .{ kb100 / 10, kb100 % 10 }) catch "?";
}

fn appendToolOpt(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) void {
    if (list.items.len > 0) list.appendSlice(allocator, ", ") catch return;
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    list.appendSlice(allocator, s) catch {};
}

/// 工具调用单行描述（`→ Read path [limit=.., offset=..]`）
pub fn formatToolCallLine(arena: Allocator, name: []const u8, args_json: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read")) {
        const path = extractJsonString(arena, args_json, "path") orelse return "→ Read";
        const offset = extractJsonInt(arena, args_json, "offset") orelse 0;
        const limit = extractJsonInt(arena, args_json, "limit") orelse 0;
        if (limit <= 0 and offset <= 0) return std.fmt.allocPrint(arena, "→ Read {s}", .{path}) catch "→ Read";
        var opts = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
        if (limit > 0) appendToolOpt(arena, &opts, "limit={d}", .{limit});
        if (offset > 0) appendToolOpt(arena, &opts, "offset={d}", .{offset});
        return std.fmt.allocPrint(arena, "→ Read {s} [{s}]", .{ path, opts.items }) catch "→ Read";
    }
    if (std.mem.eql(u8, name, "grep")) {
        const pattern = extractJsonString(arena, args_json, "pattern") orelse return "→ Grep";
        const path = extractJsonString(arena, args_json, "path") orelse "";
        const glob = extractJsonString(arena, args_json, "glob") orelse "";
        const ignore_case = extractJsonBool(arena, args_json, "ignore_case");
        const literal = extractJsonBool(arena, args_json, "literal");
        var opts = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
        if (path.len > 0 and !std.mem.eql(u8, path, ".")) appendToolOpt(arena, &opts, "path={s}", .{path});
        if (glob.len > 0) appendToolOpt(arena, &opts, "glob={s}", .{glob});
        if (ignore_case) appendToolOpt(arena, &opts, "ignore_case", .{});
        if (literal) appendToolOpt(arena, &opts, "literal", .{});
        if (opts.items.len == 0) return std.fmt.allocPrint(arena, "→ Grep \"{s}\"", .{pattern}) catch "→ Grep";
        return std.fmt.allocPrint(arena, "→ Grep \"{s}\" [{s}]", .{ pattern, opts.items }) catch "→ Grep";
    }
    if (std.mem.eql(u8, name, "find")) {
        const pattern = extractJsonString(arena, args_json, "pattern") orelse return "→ Find";
        const path = extractJsonString(arena, args_json, "path") orelse "";
        if (path.len == 0 or std.mem.eql(u8, path, ".")) return std.fmt.allocPrint(arena, "→ Find {s}", .{pattern}) catch "→ Find";
        return std.fmt.allocPrint(arena, "→ Find {s} [path={s}]", .{ pattern, path }) catch "→ Find";
    }
    if (std.mem.eql(u8, name, "ls")) {
        const path = extractJsonString(arena, args_json, "path") orelse "";
        if (path.len == 0) return "→ List .";
        return std.fmt.allocPrint(arena, "→ List {s}", .{path}) catch "→ List";
    }
    if (std.mem.eql(u8, name, "write")) {
        const path = extractJsonString(arena, args_json, "path") orelse return "→ Write";
        const content = extractJsonString(arena, args_json, "content") orelse "";
        var size_buf: [32]u8 = undefined;
        return std.fmt.allocPrint(arena, "→ Write {s} ({s})", .{ path, formatBytes(&size_buf, content.len) }) catch "→ Write";
    }

    // 未知工具：退化为参数摘要
    const summary = summarizeToolArgs(arena, args_json) catch "";
    if (summary.len == 0) return std.fmt.allocPrint(arena, "→ {s}", .{name}) catch "→ ?";
    return std.fmt.allocPrint(arena, "→ {s}: {s}", .{ name, summary }) catch "→ ?";
}

/// 块标题行：`$ 命令` / `← Edit 路径`
pub fn toolHeaderText(arena: Allocator, name: []const u8, args_json: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "bash")) {
        const cmd = extractJsonString(arena, args_json, "command") orelse return null;
        return std.fmt.allocPrint(arena, "$ {s}", .{cmd}) catch null;
    }
    if (std.mem.eql(u8, name, "edit")) {
        const path = extractJsonString(arena, args_json, "path") orelse return null;
        return std.fmt.allocPrint(arena, "← Edit {s}", .{path}) catch null;
    }
    return null;
}

/// 工具行在显示中的首行文本（块 → 块标题；非块 → 调用行描述）。
/// 失败（参数缺失等）时退化为工具名，保证永不为空（显示结构可预测）。
pub fn toolRowHeader(arena: Allocator, name: []const u8, args_json: []const u8) []const u8 {
    if (toolBlockKind(name)) |_| {
        if (toolHeaderText(arena, name, args_json)) |h| return h;
        return std.fmt.allocPrint(arena, "{s}", .{name}) catch "?";
    }
    return formatToolCallLine(arena, name, args_json);
}

/// 工具调用参数摘要（key=value 形式，截断到 ~120 字符）
pub fn summarizeToolArgs(arena: Allocator, args_json: []const u8) error{OutOfMemory}![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return "";
    const obj = switch (parsed) {
        .object => |o| o,
        else => return "",
    };

    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    var it = obj.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try out.appendSlice(arena, ", ");
        first = false;
        try out.appendSlice(arena, entry.key_ptr.*);
        try out.append(arena, '=');
        switch (entry.value_ptr.*) {
            .string => |s| try out.appendSlice(arena, s),
            .integer => |n| try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
            .float => |f| try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{f})),
            .bool => |b| try out.appendSlice(arena, if (b) "true" else "false"),
            .null => try out.appendSlice(arena, "null"),
            else => try out.appendSlice(arena, "…"),
        }
        if (out.items.len > 120) break;
    }
    // 按 UTF-8 边界截断
    var width: usize = 0;
    var i: usize = 0;
    while (i < out.items.len) {
        const n = std.unicode.utf8ByteSequenceLength(out.items[i]) catch 1;
        if (i + n > out.items.len) break;
        width += 1;
        i += n;
        if (width > 120) break;
    }
    return out.items[0..i];
}

// ── 块正文截断 / 结果摘要（迁移回填与运行时共用）──

/// 截断块正文到 max_lines 行，超出用 `…` 收尾
pub fn capBlockBody(allocator: Allocator, body: []const u8, max_lines: usize) error{OutOfMemory}![]u8 {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var shown: usize = 0;
    var truncated = false;
    while (i < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, i, '\n');
        const end = nl orelse body.len;
        if (shown >= max_lines) {
            truncated = true;
            break;
        }
        try out.appendSlice(allocator, body[i..end]);
        try out.append(allocator, '\n');
        shown += 1;
        if (nl == null) break;
        i = end + 1;
    }
    if (truncated) try out.appendSlice(allocator, "     …");
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(allocator);
}

/// 工具结果摘要（错误取首行，成功给大小）
pub fn toolResultSummary(arena: Allocator, content: []const u8, is_error: bool) error{OutOfMemory}![]const u8 {
    if (is_error) {
        const nl = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        var line = content[0..nl];
        var width: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + n > line.len) break;
            width += 1;
            i += n;
            if (width > 80) break;
        }
        line = line[0..i];
        return std.fmt.allocPrint(arena, "{s}", .{line});
    }
    var size_buf: [32]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}", .{formatBytes(&size_buf, content.len)});
}

/// 工具行的“显示正文”（与 main.zig 的物化/reloadMessage 一致）：
/// 错误行 = content；有 tool_display（edit diff）时用它；否则用 content。
pub fn toolDisplayBody(content: []const u8, tool_display: []const u8, is_error: bool) []const u8 {
    if (is_error) return content;
    if (tool_display.len > 0) return tool_display;
    return content;
}

// ── 测试 ──

const testing = std.testing;

test "display: 调用行与块标题（含退化）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings(
        "→ Read src/main.zig [limit=30, offset=2012]",
        formatToolCallLine(a, "read", "{\"path\":\"src/main.zig\",\"offset\":2012,\"limit\":30}"),
    );
    try testing.expectEqualStrings("→ Read src/main.zig", formatToolCallLine(a, "read", "{\"path\":\"src/main.zig\"}"));
    try testing.expectEqualStrings("→ List .", formatToolCallLine(a, "ls", "{}"));

    try testing.expectEqualStrings("$ echo hi", toolHeaderText(a, "bash", "{\"command\":\"echo hi\"}").?);
    try testing.expectEqualStrings("← Edit src/a.zig", toolHeaderText(a, "edit", "{\"path\":\"src/a.zig\"}").?);

    // toolRowHeader：块走标题、非块走调用行、缺参数退化
    try testing.expectEqualStrings("$ echo hi", toolRowHeader(a, "bash", "{\"command\":\"echo hi\"}"));
    try testing.expectEqualStrings("→ Read x", toolRowHeader(a, "read", "{\"path\":\"x\"}"));
    try testing.expectEqualStrings("bash", toolRowHeader(a, "bash", "{}"));
    try testing.expectEqualStrings("→ Read", toolRowHeader(a, "read", "{}"));
}

test "display: toolBlockKind 判定" {
    try testing.expectEqual(ToolBlockKind.shell, toolBlockKind("bash").?);
    try testing.expectEqual(ToolBlockKind.diff, toolBlockKind("edit").?);
    try testing.expect(toolBlockKind("read") == null);
}
