//! CLI 参数解析与输出辅助（无 AppState 依赖，可单测）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const cli_usage =
    \\SkyNet - TUI AI 编码助手
    \\
    \\用法:
    \\  skynet                        启动 TUI
    \\  skynet ask [选项] "消息"       无界面发送一轮对话（含工具调用）
    \\  skynet new [-title 标题]       新建会话
    \\  skynet sessions               列出会话
    \\  skynet messages -session <id|latest> [-n N]   查看会话消息
    \\  skynet stats [-session <id|latest>]           会话上下文/token 统计
    \\  skynet compact [-session <id|latest>]         压缩上下文（生成摘要 checkpoint）
    \\  skynet help
    \\
    \\选项:
    \\  -session <id|latest>   指定会话（默认 latest；不存在则新建）
    \\  -new                   先新建会话再发送
    \\  -title <文本>          新会话标题
    \\  -provider <名称>       临时覆盖提供商（不写回 config.json）
    \\  -model <模型id>        临时覆盖模型（不写回 config.json）
    \\  -db <路径>             数据库文件（默认 skynet.db）
    \\  -config <路径>         配置文件（默认 config.json）
    \\  -n <数量>              messages 只显示最后 N 条
    \\  --json                 以 JSON 输出结果（结构化字段，不含思考/工具原文）
    \\  --quiet                不输出过程信息（stderr）
    \\  --stream               实时把正文增量写到 stderr
    \\  --no-tools             不打印工具活动行（stderr）
    \\  --max-chars <N>        文本模式下最终回答截断为前 N 个字符
    \\  --max-context <N>      临时覆盖上下文窗口大小（便于测试自动压缩）
    \\  --thinking <级别>      思考强度 off|low|high|max（仅本次请求）
    \\  --keep-tokens <N>      压缩时保留的最近 token 数（默认 20000）
    \\
    \\约定: stdout=最终回答; stderr=过程/工具活动; 退出码 0 成功 2 参数错误 3 无可用提供商/模型 4 请求或数据库失败
    \\
;

pub const CliOptions = struct {
    command: []const u8 = "",
    session: []const u8 = "",
    new_session: bool = false,
    title: []const u8 = "",
    provider: []const u8 = "",
    model: []const u8 = "",
    /// 思考强度 off/low/high/max（仅本次请求，不写回配置）
    thinking: []const u8 = "",
    db_path: []const u8 = "skynet.db",
    config_path: []const u8 = "config.json",
    json: bool = false,
    quiet: bool = false,
    stream: bool = false,
    no_tools: bool = false,
    /// 文本模式下最终回答的截断字符数（0 = 不截断）
    max_chars: usize = 0,
    /// 临时覆盖上下文窗口（0 = 自动；小窗口便于测试自动压缩）
    max_context: u64 = 0,
    /// 压缩保留窗口 token 数（0 = 默认 20000）
    keep_tokens: usize = 0,
    limit: usize = 0,
    message: []const u8 = "",
};

pub fn isCliCommand(name: []const u8) bool {
    const known = [_][]const u8{ "ask", "new", "sessions", "messages", "stats", "compact", "help", "-h", "--help" };
    for (known) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

pub fn cliWriteStdout(io: Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn cliWriteStderr(io: Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

fn cliFlagValue(args: []const []const u8, i: *usize, short: []const u8, long: []const u8) ?[]const u8 {
    const a = args[i.*];
    if (!std.mem.eql(u8, a, short) and !std.mem.eql(u8, a, long)) return null;
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

pub fn parseCliArgs(args: []const []const u8) ?CliOptions {
    if (args.len == 0) return null;
    var opt = CliOptions{ .command = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json") or std.mem.eql(u8, a, "-json")) {
            opt.json = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "-quiet")) {
            opt.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--stream") or std.mem.eql(u8, a, "-stream")) {
            opt.stream = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-tools") or std.mem.eql(u8, a, "-no-tools")) {
            opt.no_tools = true;
            continue;
        }
        if (cliFlagValue(args, &i, "-max-chars", "--max-chars")) |v| {
            opt.max_chars = std.fmt.parseInt(usize, v, 10) catch return null;
            continue;
        }
        if (cliFlagValue(args, &i, "-max-context", "--max-context")) |v| {
            opt.max_context = std.fmt.parseInt(u64, v, 10) catch return null;
            continue;
        }
        if (cliFlagValue(args, &i, "-keep-tokens", "--keep-tokens")) |v| {
            opt.keep_tokens = std.fmt.parseInt(usize, v, 10) catch return null;
            continue;
        }
        if (std.mem.eql(u8, a, "-new") or std.mem.eql(u8, a, "--new")) {
            opt.new_session = true;
            continue;
        }
        if (cliFlagValue(args, &i, "-session", "--session")) |v| {
            opt.session = v;
            continue;
        }
        if (cliFlagValue(args, &i, "-title", "--title")) |v| {
            opt.title = v;
            continue;
        }
        if (cliFlagValue(args, &i, "-provider", "--provider")) |v| {
            opt.provider = v;
            continue;
        }
        if (cliFlagValue(args, &i, "-model", "--model")) |v| {
            opt.model = v;
            continue;
        }
        if (cliFlagValue(args, &i, "-thinking", "--thinking")) |v| {
            opt.thinking = v;
            continue;
        }
        if (cliFlagValue(args, &i, "-db", "--db")) |v| {
            opt.db_path = v;
            continue;
        }
        if (cliFlagValue(args, &i, "-config", "--config")) |v| {
            opt.config_path = v;
            continue;
        }
        if (cliFlagValue(args, &i, "-n", "--limit")) |v| {
            opt.limit = std.fmt.parseInt(usize, v, 10) catch return null;
            continue;
        }
        if (a.len > 0 and a[0] == '-') return null; // 未知选项
        if (std.mem.eql(u8, opt.command, "ask") and opt.message.len == 0) {
            opt.message = a;
            continue;
        }
        return null;
    }
    return opt;
}

pub fn cliJsonWrite(allocator: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    // 非 ASCII 转义为 \uXXXX：Windows 管道按控制台代码页解码时也不会破坏 JSON
    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .escape_unicode = true },
    };
    stringify.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// ── 测试 ──

test "CLI 参数解析" {
    try std.testing.expect(isCliCommand("ask"));
    try std.testing.expect(!isCliCommand("chat"));

    const args = [_][]const u8{ "ask", "-session", "12", "-new", "-model", "m1", "-db", "t.db", "--json", "你好" };
    const opt = parseCliArgs(&args).?;
    try std.testing.expectEqualStrings("ask", opt.command);
    try std.testing.expectEqualStrings("12", opt.session);
    try std.testing.expect(opt.new_session);
    try std.testing.expectEqualStrings("m1", opt.model);
    try std.testing.expectEqualStrings("t.db", opt.db_path);
    try std.testing.expect(opt.json);
    try std.testing.expectEqualStrings("你好", opt.message);

    const args2 = [_][]const u8{ "messages", "-session", "latest", "-n", "5" };
    const opt2 = parseCliArgs(&args2).?;
    try std.testing.expectEqual(@as(usize, 5), opt2.limit);
    try std.testing.expect(isCliCommand("stats"));

    const args3 = [_][]const u8{ "ask", "--max-chars", "120", "--no-tools", "hi" };
    const opt3 = parseCliArgs(&args3).?;
    try std.testing.expectEqual(@as(usize, 120), opt3.max_chars);
    try std.testing.expect(opt3.no_tools);

    // 未知选项 / 缺值 / 多余位置参数 → 解析失败
    try std.testing.expect(parseCliArgs(&[_][]const u8{ "ask", "--bogus" }) == null);
    try std.testing.expect(parseCliArgs(&[_][]const u8{ "ask", "-session" }) == null);
    try std.testing.expect(parseCliArgs(&[_][]const u8{ "ask", "a", "b" }) == null);
}
