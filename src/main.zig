const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tui = @import("zigtui");
const ai = @import("ai.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const md_mod = @import("markdown.zig");
const textarea_mod = @import("textarea.zig");
const clipboard = @import("clipboard.zig");
const tools_mod = @import("tools.zig");
const context_mod = @import("context.zig");
const cli = @import("cli_args.zig");

// 上下文管理纯计算（context.zig）——保留短名，避免大范围改调用点
const estimateTokens = context_mod.estimateTokens;
const toolsSchemaBytes = context_mod.toolsSchemaBytes;
const messageRequestBytes = context_mod.messageRequestBytes;
const historyRequestBytesSlice = context_mod.historyRequestBytesSlice;
const isCheckpointMessage = context_mod.isCheckpointMessage;
const CompactionRange = context_mod.CompactionRange;
const selectCompactionRange = context_mod.selectCompactionRange;
const compaction_system_prompt = context_mod.compaction_system_prompt;
const buildCompactionPayload = context_mod.buildCompactionPayload;
const cliTruncate = context_mod.truncateChars;
const fold_protect_bytes = context_mod.fold_protect_bytes;
const fold_min_bytes = context_mod.fold_min_bytes;
const fold_marker = context_mod.fold_marker;
const FoldScanner = context_mod.FoldScanner;

const system_prompt =
    "You are SkyNet, a helpful AI coding assistant with access to tools for file operations and shell commands.\n" ++
    "Guidelines:\n" ++
    "- Use the read tool to examine files instead of cat or sed.\n" ++
    "- Use write only for new files or complete rewrites; use edit for targeted changes.\n" ++
    "- old_string in edit must match the file exactly and be unique unless replace_all is true.\n" ++
    "- Use grep/find/ls to explore the codebase before making changes.\n" ++
    "- Prefer non-interactive shell commands; avoid commands that wait for input.\n" ++
    "- Be concise in your responses; show file paths clearly when working with files.";

/// TUI 程序：禁止标准库向终端输出日志/调试信息（否则会破坏全屏界面）
fn silentLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = message_level;
    _ = scope;
    _ = format;
    _ = args;
}

pub const std_options: std.Options = .{
    // error.Unexpected 会打印堆栈到 stderr（例如连接被拒绝），TUI 下必须关闭
    .unexpected_error_tracing = false,
    .logFn = silentLogFn,
};

// 崩溃时先恢复终端再打印堆栈
pub const panic = tui.panic;

const Terminal = tui.terminal.Terminal;
const Buffer = tui.render.Buffer;
const Rect = tui.render.Rect;
const Style = tui.style.Style;
const Block = tui.widgets.Block;
const Borders = tui.widgets.Borders;
const BorderSymbols = tui.widgets.BorderSymbols;
const TextInput = tui.widgets.TextInput;

const Mode = enum {
    normal,
    model_select,
    provider_models,
    provider_add,
    provider_confirm,
    compact_confirm,
    thinking_select,
    preset_select,
    session_select,
    session_confirm,
    help_select,
};

const HelpCommand = struct {
    name: []const u8,
    desc: []const u8,
};

const help_commands = [_]HelpCommand{
    .{ .name = "sessions", .desc = "打开会话选择菜单" },
    .{ .name = "models", .desc = "打开模型/提供商选择菜单" },
    .{ .name = "compact", .desc = "压缩当前会话（/compact [保留token]，默认 20000）" },
    .{ .name = "thinking", .desc = "切换思考强度（/thinking off|low|high|max）" },
    .{ .name = "exit", .desc = "退出程序" },
};

/// 合法思考强度（"" 表示默认不发送）
fn isThinkingLevel(s: []const u8) bool {
    const known = [_][]const u8{ "off", "low", "high", "max" };
    for (known) |k| {
        if (std.mem.eql(u8, s, k)) return true;
    }
    return false;
}

/// 思考强度候选（DeepSeek flash 支持 low；其余给 off/high/max）
const thinking_levels_base = [_][]const u8{ "off", "high", "max" };
const thinking_levels_flash = [_][]const u8{ "off", "low", "high", "max" };

fn thinkingLevelsFor(model: []const u8) []const []const u8 {
    if (std.ascii.indexOfIgnoreCase(model, "flash") != null) return &thinking_levels_flash;
    return &thinking_levels_base;
}

fn firstToken(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != ' ') : (i += 1) {}
    return s[0..i];
}

fn isKnownCommand(name: []const u8) bool {
    const known = [_][]const u8{ "help", "h", "?", "models", "sessions", "compact", "thinking", "exit" };
    for (known) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

/// 输入是否为指令：以 / 开头且首词是已知指令
fn isCommandInput(input: []const u8) bool {
    if (input.len == 0 or input[0] != '/') return false;
    return isKnownCommand(firstToken(input[1..]));
}

/// 粘贴时换行会以 Enter 事件形式到达。用事件间隔区分：
/// 粘贴是毫秒级突发，人类两次按键间隔通常远大于此阈值。
const paste_enter_threshold_ms = 20;

fn isPasteNewline(delta_ms: i64) bool {
    return delta_ms >= 0 and delta_ms < paste_enter_threshold_ms;
}

/// 把粘贴文本插入指定输入框（清洗非法 UTF-8，避免污染历史/请求体）；
/// 返回实际插入字节数（小于 text.len 表示达到输入框软上限被截断/未插入）
fn insertPastedText(allocator: Allocator, input: anytype, text: []const u8) usize {
    const before = input.value().len;
    if (std.unicode.utf8ValidateSlice(text)) {
        input.insertBytes(text);
    } else if (ai.sanitizeUtf8(allocator, text)) |clean| {
        defer allocator.free(clean);
        input.insertBytes(clean);
    } else |_| {}
    return input.value().len - before;
}

const RecentEntry = struct {
    provider: usize = 0,
    name: [128]u8 = undefined,
    len: usize = 0,
};

/// 工具块渲染类型：shell 输出 / 行号 diff
const ToolBlockKind = enum { shell, diff };

const Message = struct {
    content: []const u8 = "",
    style: Style,
    /// Markdown 解析结果（仅 AI 回复使用，为 null 时按纯文本渲染）
    md: ?[]md_mod.Line = null,
    /// 用户消息：左侧渲染粉紫色竖条
    user: bool = false,
    /// 工具块：整块 rgb(20,20,20) 背景，按类型着色（首行为标题）
    tool_block: ?ToolBlockKind = null,
    /// 工具块是否执行失败（标题行标红）
    tool_error: bool = false,
    /// 思考过程（仅展示，不进历史；落库由 finalize 负责）
    reasoning: ?[]u8 = null,
    reasoning_start_ms: i64 = 0,
    reasoning_end_ms: i64 = 0,
    /// 定格后的思考耗时（毫秒；从数据库恢复时直接使用）
    reasoning_ms: i64 = 0,
    reasoning_expanded: bool = false,
};

/// 思考块可点击行（用于鼠标展开/折叠）
const ThoughtRow = struct {
    y: u16,
    msg: usize,
};

const max_thought_rows = 64;

// ── 文本选择（内容坐标锚定）──

const SelPoint = struct {
    msg: usize = 0,
    /// 该消息内的内容来源（思考内容排在正文之前）
    source: SelSource = .content,
    off: usize = 0,
};

/// 选区内容的来源：思考块 / 正文
const SelSource = enum(u8) { reasoning, content };

/// 非内容片段的偏移哨兵（如表格边框/填充空格）
const sel_no_off = std.math.maxInt(usize);

const SelSegment = struct {
    text: []const u8,
    /// 消息内容内的字节偏移；sel_no_off 表示不在内容中
    off: usize = sel_no_off,
    x: u16 = 0,
    width: u16 = 0,
};

const sel_segments_per_row = 32;

const SelRow = struct {
    y: u16 = 0,
    msg: usize = 0,
    source: SelSource = .content,
    segs: [sel_segments_per_row]SelSegment = undefined,
    seg_count: u8 = 0,
};

/// 选区所属区域（不允许跨区选择）
const SelArea = enum { messages, input };

/// 输入框可视行的映射（输入内容在缓冲内是连续的，故只需字节范围）
const InputSelRow = struct {
    y: u16 = 0,
    start: usize = 0,
    end: usize = 0,
    x: u16 = 0,
};

const max_input_sel_rows = 16;

const max_sel_rows = 128;

/// 用于排序的（消息, 来源）位置；思考内容排在正文之前
const PartPos = struct {
    msg: usize,
    source: SelSource,
};

fn partLess(a: PartPos, b: PartPos) bool {
    if (a.msg != b.msg) return a.msg < b.msg;
    return @intFromEnum(a.source) < @intFromEnum(b.source);
}

fn partEql(a: PartPos, b: PartPos) bool {
    return a.msg == b.msg and a.source == b.source;
}

fn selPointPos(p: SelPoint) PartPos {
    return .{ .msg = p.msg, .source = p.source };
}

fn selPointLess(a: SelPoint, b: SelPoint) bool {
    return partLess(selPointPos(a), selPointPos(b)) or
        (partEql(selPointPos(a), selPointPos(b)) and a.off < b.off);
}

fn orderSelPoints(a: SelPoint, b: SelPoint) [2]SelPoint {
    if (selPointLess(a, b)) return .{ a, b };
    return .{ b, a };
}

/// 跨消息/跨来源提取选中文本（两个端点自动排序，偏移会裁剪到内容长度内）
fn extractSelectionText(
    allocator: std.mem.Allocator,
    contents: []const []const u8,
    reasonings: []const []const u8,
    a: SelPoint,
    b: SelPoint,
) ![]u8 {
    const lo_hi = orderSelPoints(a, b);
    const lo = lo_hi[0];
    const hi = lo_hi[1];
    const lo_pos = selPointPos(lo);
    const hi_pos = selPointPos(hi);

    var out: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    var mi = lo.msg;
    while (mi <= hi.msg) : (mi += 1) {
        if (mi >= contents.len) break;
        // 每条消息内的顺序：思考内容 → 正文
        const sources = [_]SelSource{ .reasoning, .content };
        for (sources) |src| {
            const pos: PartPos = .{ .msg = mi, .source = src };
            if (partLess(pos, lo_pos) or partLess(hi_pos, pos)) continue;
            const src_text: []const u8 = switch (src) {
                .reasoning => if (mi < reasonings.len) reasonings[mi] else "",
                .content => contents[mi],
            };
            const start: usize = if (partEql(pos, lo_pos)) @min(lo.off, src_text.len) else 0;
            const end: usize = if (partEql(pos, hi_pos)) @min(hi.off, src_text.len) else src_text.len;
            if (end <= start) continue;
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, src_text[start..end]);
        }
    }
    return out.toOwnedSlice(allocator);
}

const Utf8Char = struct { cp: u21, len: usize };

fn decodeUtf8At(text: []const u8, i: usize) Utf8Char {
    var len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    if (i + len > text.len) len = 1;
    const cp: u21 = if (len == 1)
        text[i]
    else
        std.unicode.utf8Decode(text[i .. i + len]) catch 0xFFFD;
    return .{ .cp = cp, .len = len };
}

/// 片段内列偏移 → 字节偏移
fn offsetInSegment(seg: SelSegment, col_off: u16) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < seg.text.len) {
        const dec = decodeUtf8At(seg.text, i);
        const w: usize = tui.render.codepointWidth(dec.cp);
        if (w > 0 and col + w > col_off) return i;
        col += w;
        i += dec.len;
    }
    return seg.text.len;
}

/// 文本区间内列偏移 → 绝对字节偏移
fn offsetInRange(text: []const u8, start: usize, end: usize, col_off: u16) usize {
    var col: usize = 0;
    var i = start;
    while (i < end) {
        const dec = decodeUtf8At(text, i);
        const w: usize = tui.render.codepointWidth(dec.cp);
        if (w > 0 and col + w > col_off) return i;
        col += w;
        i += dec.len;
    }
    return end;
}

/// 输入框选中内容 = 输入缓冲的字节切片（两端自动排序、越界裁剪）
fn extractInputSelection(text: []const u8, a: usize, b: usize) []const u8 {
    const x = @min(a, text.len);
    const y = @min(b, text.len);
    const lo = @min(x, y);
    const hi = @max(x, y);
    return text[lo..hi];
}

// 思考块显示模式：暂硬编码 auto（思考时流式展开，思考完成后自动折叠），后续接入配置

/// 输入框软上限在 textarea.zig（max_input_bytes，8MB 动态缓冲）
/// 外部写入轮询间隔（毫秒）
const external_poll_interval_ms = 500;

/// 每帧最多处理的事件数（防止输入洪峰饿死重绘；超出部分留到下一帧）
const max_events_per_frame: usize = 1024;

/// 生成中可排队等待发送的消息上限（防止连打堆积）
const max_pending_sends: usize = 32;

// ── 旧工具输出折叠（控制上下文占用）──
// 折叠/压缩的纯计算在 context.zig（保护窗口、批量阈值、区间选择等）
const StreamStatus = enum(u8) { idle, running, done, failed, canceled };

/// 交给模型的工具 schema（映射自 tools.zig）
const tool_schemas = blk: {
    var arr: [tools_mod.tool_defs.len]ai.ToolSchema = undefined;
    for (tools_mod.tool_defs, 0..) |d, i| {
        arr[i] = .{ .name = d.name, .description = d.description, .parameters = d.parameters };
    }
    break :blk arr;
};

const StreamEventKind = enum { turn_end, tool_start, tool_end, user_sent };

const StreamEvent = struct {
    kind: StreamEventKind,
    name: []u8 = &.{},
    text: []u8 = &.{},
    /// 原始参数 JSON（用于构建块标题）
    args: []u8 = &.{},
    /// 块内容（bash 输出 / edit diff 文本）
    payload: []u8 = &.{},
    is_error: bool = false,
};

/// 单个工具调用的渲染元数据（落库 + 重启后重建工具块用；arena 所有）
const ToolMeta = struct {
    id: []const u8,
    name: []const u8,
    display: []const u8 = "",
    is_error: bool = false,
};

/// 转录条目：消息 + 该回合的思考内容（落库供重启恢复）+ 该轮 token 用量
const TranscriptEntry = struct {
    msg: ai.Message,
    reasoning: []const u8 = "",
    reasoning_ms: i64 = 0,
    usage: ai.Usage = .{},
};

/// 流式请求的工作线程与共享数据（历史/配置均快照，避免与主线程竞争）
const StreamJob = struct {
    app: *AppState,
    arena: std.heap.ArenaAllocator,
    io: Io,
    cwd: []const u8,
    model: []const u8,
    endpoint: []const u8,
    api_key: []const u8,
    provider_name: []const u8,
    session_id: []const u8 = "",
    behavior: config_mod.Behavior = .{},
    environ_map: ?*const std.process.Environ.Map = null,
    /// 数据库路径（工作线程实时落库/中途压缩时自建连接用；arena 所有，含终止符）
    db_path: [:0]const u8 = "",
    /// 会话的数字 id（worker 实时落库用；0 = 不落库，回退到 finalize 批量写）
    session_id_num: i64 = 0,
    /// 中途压缩参数快照
    auto_compact_pct: u64 = 0,
    context_window: u64 = 0,
    keep_recent_tokens: usize = 0,
    /// usage 锚点（0 = 无）：job.history 前 anchor_len 条 ≈ anchor_tokens 个 token
    anchor_len: usize = 0,
    anchor_tokens: u64 = 0,
    /// 本回合是否发生过中途压缩（finalize 后需按 checkpoint 重建主线程历史）
    compacted_midturn: bool = false,
    /// 服务端错误详情（失败时带回给主线程展示）
    error_detail: []const u8 = "",
    /// 本回合累计的 token 用量（含缓存命中）
    usage_input: u64 = 0,
    usage_output: u64 = 0,
    usage_cached: u64 = 0,
    /// 当前轮（单次请求）的用量：写入对应的 assistant 消息
    round_usage: ai.Usage = .{},
    history: []ai.Message,
    /// 本轮代理产生的消息（assistant 工具调用 + tool 结果 + 最终回复）
    transcript: std.ArrayListUnmanaged(TranscriptEntry) = .{ .items = &.{}, .capacity = 0 },
    /// 当前回合累积的正文（arena 所有）
    content: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },
    /// 当前回合累积的思考内容（arena 所有，每轮清空）
    reasoning: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },
    reasoning_start_ms: i64 = 0,
    reasoning_end_ms: i64 = 0,
    /// 工具渲染元数据（与 transcript 中的 tool 消息按 id 对应；arena 所有）
    tool_meta: std.ArrayListUnmanaged(ToolMeta) = .{ .items = &.{}, .capacity = 0 },

    fn deinit(self: *StreamJob) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// 剪贴板写入函数签名（生产环境用 clipboard.setText；测试可注入 fake）
const ClipboardWriter = *const fn (std.mem.Allocator, []const u8) bool;

const AppState = struct {
    running: bool = true,
    mode: Mode = .normal,
    io: Io = undefined,
    allocator: std.mem.Allocator = undefined,
    config: config_mod.Config = .{},
    db: ?db_mod.Db = null,
    /// 数据库路径（仅当 db 为 null 时的兜底；worker 自建连接优先用 db.path）。
    /// 留空 = 未显式指定：worker 不会去猜默认路径（防止误开无关库）。
    db_path: []const u8 = "",
    session_id: i64 = 0,
    history: std.ArrayListUnmanaged(ai.Message) = .{ .items = &.{}, .capacity = 0 },

    // 会话路由标识（按 SkyNet 会话生成，切换会话时更新；发给网关的亲和头）
    session_uuid: [36]u8 = undefined,
    session_uuid_ready: bool = false,
    session_uuid_for: i64 = -1,
    /// 环境变量表（用于 HTTP_PROXY/HTTPS_PROXY）
    environ_map: ?*const std.process.Environ.Map = null,

    // 流式回复状态
    stream_status: std.atomic.Value(u8) = .init(@intFromEnum(StreamStatus.idle)),
    stream_cancel: std.atomic.Value(bool) = .init(false),
    stream_thread: ?std.Thread = null,
    stream_job: ?*StreamJob = null,
    stream_mutex: Io.Mutex = .init,
    stream_buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },
    stream_consume_pos: usize = 0,
    stream_reasoning_buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },
    stream_reasoning_pos: usize = 0,
    /// 工具调用/回合事件（worker → 主线程，按序消费）
    stream_events: std.ArrayListUnmanaged(StreamEvent) = .{ .items = &.{}, .capacity = 0 },
    stream_error: ?ai.AIError = null,

    /// 生成/压缩期间用户提交、等待发送的消息（主线程入队；worker 在工具轮次边界取走注入）
    pending_sends_mutex: Io.Mutex = .init,
    pending_sends: std.ArrayListUnmanaged([]u8) = .{ .items = &.{}, .capacity = 0 },
    /// 最近一次请求的 token 用量；无真实数据时为历史估算值（见 usage_estimated）
    last_usage: ai.Usage = .{},
    /// 本轮最后一个请求的用量（上下文占用显示：工具循环的多轮请求不累计）
    context_usage: ai.Usage = .{},
    /// usage 锚点：history 前 usage_anchor_len 条 ≈ usage_anchor_tokens 个 token。
    /// 回合收尾时记录（真实 usage）；折叠时递减；历史重建/新会话时清空。
    usage_anchor_len: ?usize = null,
    usage_anchor_tokens: u64 = 0,
    /// last_usage 是否来自估算（尚无真实 usage 时为 true，状态栏显示 ~ 前缀）
    usage_estimated: bool = true,

    // 外部写入检测（CLI/其他进程写同一会话时，TUI 增量刷新）
    /// 当前会话已加载到的最大消息 id
    last_seen_msg_id: i64 = 0,
    /// 上次观察到的 SQLite data_version
    db_data_version: i64 = 0,
    last_db_poll_ms: i64 = 0,

    // 上下文压缩（compaction）
    /// 上下文窗口覆盖（0 = 用 provider 配置/启发式；CLI --max-context 用）
    context_window_override: u64 = 0,
    /// 自动压缩触发阈值（窗口百分比；0 = 关闭）
    auto_compact_pct: u64 = 75,
    /// 压缩时保留的最近 token 数
    keep_recent_tokens: usize = 20_000,
    /// 已加载的最近 compaction id（用于发现外部压缩）
    last_compaction_id: i64 = 0,

    // 异步压缩（TUI /compact）：worker 流式产出摘要，主线程渲染
    compact_status: std.atomic.Value(u8) = .init(0), // 0 idle / 1 running / 2 finished
    compact_cancel: std.atomic.Value(bool) = .init(false),
    compact_thread: ?std.Thread = null,
    compact_plan: ?*CompactionPlan = null,
    compact_mutex: Io.Mutex = .init,
    compact_buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },
    compact_consume_pos: usize = 0,
    /// 压缩提示标题消息下标 / 正在流式的摘要正文消息下标
    compact_head_idx: ?usize = null,
    compact_msg_idx: ?usize = null,
    streaming_msg_idx: ?usize = null,
    message_wrap_width: usize = 0,

    // 思考块点击区域（每帧重建）
    thought_rows: [max_thought_rows]ThoughtRow = undefined,
    thought_row_count: usize = 0,

    // 模型/提供商选择状态
    model_select_index: usize = 0,
    model_view_start: usize = 0,
    model_select_models: []ai.ModelInfo = &.{},
    model_select_provider: usize = 0,
    model_select_recent: [5]RecentEntry = undefined,
    model_select_recent_count: usize = 0,

    // 添加提供商表单
    provider_form_name: TextInput(256) = .{
        .style = .{ .fg = .white },
        .cursor_style = .{ .fg = .black, .bg = .white },
        .placeholder = "例如: LM-Studio",
        .focused = true,
    },
    provider_form_url: TextInput(256) = .{
        .style = .{ .fg = .white },
        .cursor_style = .{ .fg = .black, .bg = .white },
        .placeholder = "例如: http://127.0.0.1:1234/v1",
        .focused = false,
    },
    provider_form_key: TextInput(256) = .{
        .style = .{ .fg = .white },
        .cursor_style = .{ .fg = .black, .bg = .white },
        .placeholder = "可留空",
        .focused = false,
    },
    provider_form_key_env: TextInput(256) = .{
        .style = .{ .fg = .white },
        .cursor_style = .{ .fg = .black, .bg = .white },
        .placeholder = "可留空，如 OPENAI_API_KEY",
        .focused = false,
    },
    provider_form_field: usize = 0,
    provider_edit_index: ?usize = null,
    /// 表单所属预设 id（空 = 自定义）
    provider_form_preset: [64]u8 = undefined,
    provider_form_preset_len: usize = 0,
    /// 删除提供商确认：待删除的提供商下标
    provider_confirm_index: ?usize = null,

    // 预设选择器
    preset_select_index: usize = 0,

    // 思考强度选择器
    thinking_select_index: usize = 0,

    // 消息滚动状态
    scroll_offset: usize = 0,
    terminal_height: u16 = 0,
    menu_visible_rows: usize = 0,
    message_visible_rows: usize = 0,

    // 会话选择状态
    session_list: []const db_mod.SessionListRow = &.{},
    session_select_index: usize = 0,
    session_view_start: usize = 0,

    // 文本选择状态（内容坐标锚定，滚动时高亮跟随文本；不允许跨输入框/消息区）
    sel_area: SelArea = .messages,
    sel_anchor: SelPoint = .{},
    sel_current: SelPoint = .{},
    sel_active: bool = false,
    sel_dragging: bool = false,
    drag_x: u16 = 0,
    drag_y: u16 = 0,
    /// 边缘拖动自动滚动方向：-1 向上（更早），1 向下（更新），0 无
    auto_scroll_dir: i8 = 0,
    sel_rows: [max_sel_rows]SelRow = undefined,
    sel_row_count: usize = 0,
    input_sel_rows: [max_input_sel_rows]InputSelRow = undefined,
    input_sel_row_count: usize = 0,

    // 右上角临时悬浮通知（如"已复制 3 字符"、切换思考强度）
    toast: [96]u8 = undefined,
    toast_len: usize = 0,
    toast_until_ms: i64 = 0,

    // 删除会话确认状态
    confirm_session_id: i64 = 0,
    confirm_title: [128]u8 = undefined,
    confirm_title_len: usize = 0,
    confirm_stage: u8 = 0, // 1=第一次确认 2=第二次确认
    confirm_yes: bool = false, // 光标是否在"是"上（默认在"否"）

    // 帮助菜单状态
    help_select_index: usize = 0,

    // 菜单返回栈（单级）：从菜单中打开另一个菜单时记录，Esc 返回上一级
    menu_parent: ?Mode = null,

    input: textarea_mod.TextArea = .{
        .style = .{ .fg = .white },
        .cursor_style = .{ .fg = .black, .bg = .white },
        .placeholder = "输入消息，Enter 发送，Ctrl+J 换行 (Esc 菜单)",
        .focused = true,
    },
    input_wrap_width: usize = 80,
    input_box_top: u16 = 0,
    input_content_rows: usize = 0,
    last_key_ms: i64 = 0,
    /// 光标闪烁相位起点（按键/点击后重置，保持短暂实心）
    blink_anchor_ms: i64 = 0,

    messages: std.ArrayListUnmanaged(Message) = .{ .items = &.{}, .capacity = 0 },

    fn currentProvider(self: *AppState) ?*config_mod.Provider {
        if (self.config.providers.items.len == 0) return null;
        for (self.config.providers.items) |*p| {
            if (std.mem.eql(u8, p.name, self.config.current_provider_name)) return p;
        }
        return &self.config.providers.items[0];
    }

    fn currentProviderIndex(self: *AppState) ?usize {
        for (self.config.providers.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, self.config.current_provider_name)) return i;
        }
        return null;
    }

    fn isCurrentProvider(self: *AppState, idx: usize) bool {
        if (idx >= self.config.providers.items.len) return false;
        return std.mem.eql(u8, self.config.providers.items[idx].name, self.config.current_provider_name);
    }

    fn providerNameExists(self: *AppState, name: []const u8, exclude_idx: ?usize) bool {
        for (self.config.providers.items, 0..) |p, i| {
            if (exclude_idx) |ex| {
                if (i == ex) continue;
            }
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        return false;
    }

    fn currentModel(self: *AppState) []const u8 {
        return self.config.current_model;
    }

    fn addMessage(self: *AppState, content: []const u8, style: Style) void {
        self.addMessageImpl(content, style, false, true);
    }

    /// 流式追加的提示行：上翻阅读时保持视口不动（不跳到底部）
    fn addStreamMessage(self: *AppState, content: []const u8, style: Style) void {
        self.addMessageImpl(content, style, false, false);
    }

    /// 用户消息：绿色文字 + 左侧粉紫色竖条
    fn addUserMessage(self: *AppState, content: []const u8) void {
        if (content.len == 0) return;
        const owned = self.allocator.dupe(u8, content) catch return;
        self.messages.append(self.allocator, .{
            .content = owned,
            .style = .{ .fg = .green },
            .user = true,
        }) catch {
            self.allocator.free(owned);
            return;
        };
        self.scroll_offset = 0;
    }

    fn addMessageImpl(self: *AppState, content: []const u8, style: Style, markdown: bool, stick: bool) void {
        if (content.len == 0) return;
        const owned = self.allocator.dupe(u8, content) catch return;
        var parsed: ?[]md_mod.Line = null;
        if (markdown) {
            parsed = md_mod.parse(self.allocator, owned, md_mod.default_styles) catch null;
        }
        self.messages.append(self.allocator, .{
            .content = owned,
            .style = style,
            .md = parsed,
        }) catch {
            self.allocator.free(owned);
            if (parsed) |md| md_mod.free(self.allocator, md);
            return;
        };
        if (stick) {
            self.scroll_offset = 0;
        } else {
            self.preserveViewOnAppend();
        }
    }

    /// 追加消息后的滚动处理：上翻时按新增行数补偿偏移保持视口，贴底时继续跟随。
    /// 注意：新消息会让"上一条"末尾多出一个消息间隔空行，该行同样计入总行数
    fn preserveViewOnAppend(self: *AppState) void {
        const width = self.message_wrap_width;
        if (width == 0 or self.scroll_offset == 0) return;
        if (self.messages.items.len == 0) return;
        const rows = messageRowCount(self.messages.items[self.messages.items.len - 1], width);
        const sep: usize = if (self.messages.items.len > 1) 1 else 0;
        if (rows + sep > 0) self.scroll_offset +|= rows + sep;
    }

    fn freeDisplayMessage(self: *AppState, msg: Message) void {
        if (msg.content.len > 0) self.allocator.free(msg.content);
        if (msg.reasoning) |r| self.allocator.free(r);
        if (msg.md) |md| md_mod.free(self.allocator, md);
    }

    /// 向对话历史追加一条消息（role 与 content 都会被复制，退出时统一释放）
    fn appendHistory(self: *AppState, role: []const u8, content: []const u8) void {
        if (content.len == 0) return;
        self.appendHistoryMessage(.{ .role = role, .content = content });
    }

    /// 深拷贝一条消息（含工具字段）追加到内存历史
    fn appendHistoryMessage(self: *AppState, m: ai.Message) void {
        const copy = cloneMessage(self.allocator, m) catch return;
        self.history.append(self.allocator, copy) catch {
            freeMessage(self.allocator, copy);
        };
    }

    /// 持久化一条消息并追加到内存历史（思考内容只落库，不进历史）
    fn recordMessage(
        self: *AppState,
        role: []const u8,
        content: []const u8,
        model: []const u8,
        provider: []const u8,
        reasoning: []const u8,
        reasoning_ms: i64,
    ) void {
        // 入口清洗：非法 UTF-8 会让 JSON 序列化退化为字节数组并污染历史
        const safe_content = sanitizeDup(self.allocator, content) catch return;
        defer self.allocator.free(safe_content);
        const safe_reasoning: ?[]u8 = if (reasoning.len > 0)
            (sanitizeDup(self.allocator, reasoning) catch null)
        else
            null;
        defer if (safe_reasoning) |r| self.allocator.free(r);

        const db_id = self.persistMessage(.{
            .role = role,
            .content = safe_content,
            .model = model,
            .provider = provider,
            .reasoning = if (safe_reasoning) |r| r else "",
            .reasoning_ms = reasoning_ms,
        });
        self.appendHistoryMessage(.{ .role = role, .content = safe_content, .db_id = db_id });
    }

    /// 只落库（不进历史，历史由调用方负责）；返回消息行 id（无库或失败为 0）
    fn persistMessage(self: *AppState, msg: db_mod.NewMessage) i64 {
        if (self.session_id == 0) return 0;
        const db = if (self.db) |*d| d else return 0;
        var m = msg;
        m.session_id = self.session_id;
        const id = db.insertMessage(m) catch 0;
        if (std.mem.eql(u8, m.role, "user")) {
            db.maybeSetSessionTitle(self.session_id, m.content) catch {};
        }
        if (id > self.last_seen_msg_id) self.last_seen_msg_id = id;
        return id;
    }

    /// 空闲时检测其他进程（如 CLI）写入当前会话的新消息并增量追加（外部聊天实时可见）。
    /// 用 SQLite data_version 判断外部提交，避免每帧都查消息表。
    fn pollExternalUpdates(self: *AppState) void {
        if (self.isStreaming()) return;
        const db = if (self.db) |*d| d else return;

        const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (now - self.last_db_poll_ms < external_poll_interval_ms) return;
        self.last_db_poll_ms = now;

        const dv = db.dataVersion() catch return;
        if (dv == self.db_data_version) return;
        self.db_data_version = dv;

        // 外部进程做了压缩：history 结构已变，整会话重载
        const cp = db.latestCompaction(self.session_id) catch null;
        const cp_id = if (cp) |c| c.id else 0;
        if (cp_id != self.last_compaction_id) {
            self.last_compaction_id = cp_id;
            self.clearHistory();
            self.clearDisplay();
            self.loadSessionContent(self.session_id);
            self.setToast("会话已被外部压缩，已重载");
            return;
        }

        const rows = db.loadMessagesAfter(self.session_id, self.last_seen_msg_id) catch return;
        if (rows.len == 0) return;

        const offset_before = self.scroll_offset;
        const msgs_before = self.messages.items.len;
        self.applyLoadedMessages(rows);
        // 上翻阅读时按新增行数补偿偏移；贴底时跟随最新
        if (offset_before > 0 and self.message_wrap_width > 0) {
            var added: usize = 0;
            for (self.messages.items[msgs_before..]) |m| added += messageRowCount(m, self.message_wrap_width);
            if (added > 0) self.scroll_offset +|= added;
        } else {
            self.scroll_offset = 0;
        }
        self.setToast("会话已由外部更新");
    }

    /// 有效上下文窗口：CLI 覆盖 > provider 配置 > 模型名启发式
    fn contextWindowCurrent(self: *AppState) u64 {
        if (self.context_window_override > 0) return self.context_window_override;
        if (self.currentProvider()) |p| {
            if (p.opt_context_window > 0) return p.opt_context_window;
        }
        const model = self.currentModel();
        return if (model.len > 0) modelContextWindow(model) else 131_072;
    }

    /// 估算当前请求 token。有真实 usage 锚点（上一轮服务端计数）时用「锚点 token + 其后增量」，
    /// 否则退化为纯 chars/4 估算（会低估中文密集内容；启动第一轮/重建历史后如此）。
    fn estimateRequestTokens(self: *AppState) usize {
        if (self.usage_anchor_len) |anchor_len| {
            if (anchor_len <= self.history.items.len and self.usage_anchor_tokens > 0) {
                const inc = historyRequestBytesSlice(self.history.items[anchor_len..]);
                return @intCast(self.usage_anchor_tokens + estimateTokens(inc));
            }
        }
        var has_system = false;
        for (self.history.items) |m| {
            if (std.mem.eql(u8, m.role, "system")) {
                has_system = true;
                break;
            }
        }
        var bytes = historyRequestBytesSlice(self.history.items) + toolsSchemaBytes();
        if (!has_system) bytes += system_prompt.len;
        return estimateTokens(bytes);
    }

    /// 无真实 usage 时用历史估算填充上下文占用（启动/加载/压缩后即可显示）
    fn refreshEstimatedUsage(self: *AppState) void {
        self.last_usage = .{ .input_tokens = self.estimateRequestTokens() };
        self.context_usage = self.last_usage;
        self.usage_estimated = true;
        // 估算值替换真实 usage → 锚点失效（history 常在本函数前被重建）
        self.usage_anchor_len = null;
        self.usage_anchor_tokens = 0;
    }

    /// 接近窗口阈值时自动压缩（在发起新一轮请求前调用）
    fn maybeAutoCompact(self: *AppState) void {
        if (self.auto_compact_pct == 0) return;
        const window = self.contextWindowCurrent();
        if (window == 0) return;
        const est = self.estimateRequestTokens();
        if (est * 100 < window * self.auto_compact_pct) return;
        _ = self.runCompaction(0);
    }

    /// 同步执行一次上下文压缩（自动触发 / CLI 用；TUI 手动走异步 startCompaction）。
    /// keep_tokens_override > 0 时覆盖保留窗口（CLI --keep-tokens）。
    fn runCompaction(self: *AppState, keep_tokens_override: usize) CompactionOutcome {
        var outcome = CompactionOutcome{};
        if (self.isStreaming() or self.isCompacting()) {
            outcome.err = "正在生成中";
            return outcome;
        }
        const provider = self.currentProvider() orelse {
            outcome.err = "无可用提供商";
            return outcome;
        };
        const model = self.currentModel();
        if (model.len == 0) {
            outcome.err = "未选择模型";
            return outcome;
        }
        if (self.db == null) {
            outcome.err = "数据库不可用";
            return outcome;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var plan = CompactionPlan{
            .app = self,
            .arena = &arena,
            .io = self.io,
            .async = false,
            .db_path = "",
            .session_id = self.session_id,
            .endpoint = provider.endpoint,
            .api_key = self.resolvedApiKey(provider),
            .model = model,
            .provider_name = provider.name,
            .behavior = config_mod.behavior(provider),
            .environ_map = self.environ_map,
            .history = self.history.items,
            .keep_tokens = if (keep_tokens_override > 0) keep_tokens_override else self.keep_recent_tokens,
        };
        self.compact_cancel.store(false, .release);
        compactionExecute(&plan);

        outcome.compacted = plan.compacted;
        outcome.summarized_messages = plan.summarized;
        outcome.summary_len = plan.summary_len;
        outcome.tokens_before = plan.tokens_before;
        outcome.tail_start_id = plan.tail_start_id;
        outcome.err = plan.err;
        outcome.err_detail_len = plan.err_detail_len;
        if (plan.err_detail_len > 0) {
            @memcpy(outcome.err_detail_buf[0..plan.err_detail_len], plan.err_detail_buf[0..plan.err_detail_len]);
        }

        if (plan.compacted) {
            self.last_usage = .{};
            self.context_usage = .{};
            self.loadSessionContent(self.session_id);
        }
        return outcome;
    }

    fn clearDisplay(self: *AppState) void {
        for (self.messages.items) |msg| {
            self.freeDisplayMessage(msg);
        }
        self.messages.clearRetainingCapacity();
        self.scroll_offset = 0;
        self.clearSelection();
    }

    fn clearSelection(self: *AppState) void {
        self.sel_active = false;
        self.sel_dragging = false;
        self.auto_scroll_dir = 0;
    }

    /// 根据拖动位置更新自动滚动方向（消息区/输入框各自判定；仅在确实可以滚动时启动）
    fn updateAutoScrollDir(self: *AppState) void {
        self.auto_scroll_dir = 0;
        if (!self.sel_dragging) return;

        switch (self.sel_area) {
            .messages => {
                const rows = self.sel_rows[0..self.sel_row_count];
                if (rows.len == 0) return;
                if (self.drag_y <= rows[0].y) {
                    self.auto_scroll_dir = -1;
                } else if (self.drag_y >= rows[rows.len - 1].y) {
                    self.auto_scroll_dir = 1;
                }
            },
            .input => {
                const rows = self.input_sel_rows[0..self.input_sel_row_count];
                if (rows.len == 0) return;
                if (self.drag_y <= rows[0].y) {
                    // 向上：视口上方还有更早的行时才启动
                    if (self.input.canScrollUp()) self.auto_scroll_dir = -1;
                } else if (self.drag_y >= rows[rows.len - 1].y) {
                    // 向下：视口下方还有更晚的行时才启动
                    if (self.input.canScrollDown(self.input_wrap_width, self.input_content_rows)) {
                        self.auto_scroll_dir = 1;
                    }
                }
            },
        }
    }

    /// 自动滚动后用最新行映射重算选区端点（在绘制之后调用）
    fn refreshDragSelection(self: *AppState) void {
        if (!self.sel_dragging) return;
        switch (self.sel_area) {
            .messages => {
                if (self.pointFromScreen(self.drag_x, self.drag_y)) |p| {
                    self.sel_current = p;
                }
            },
            .input => {
                if (self.pointFromInputClamped(self.drag_x, self.drag_y)) |p| {
                    self.sel_current = p;
                }
            },
        }
    }

    /// 停止拖动（保留选区）；用于按键打断等场景
    fn stopDragging(self: *AppState) void {
        self.sel_dragging = false;
        self.auto_scroll_dir = 0;
    }

    /// 让光标在模型列表视口内可见
    fn clampModelViewStart(self: *AppState, visible: usize) void {
        if (visible == 0) return;
        if (self.model_select_index < self.model_view_start) {
            self.model_view_start = self.model_select_index;
        } else if (self.model_select_index >= self.model_view_start + visible) {
            self.model_view_start = self.model_select_index - visible + 1;
        }
    }

    /// 让光标在会话列表视口内可见
    fn clampSessionViewStart(self: *AppState, visible: usize) void {
        if (visible == 0) return;
        if (self.session_select_index < self.session_view_start) {
            self.session_view_start = self.session_select_index;
        } else if (self.session_select_index >= self.session_view_start + visible) {
            self.session_view_start = self.session_select_index - visible + 1;
        }
    }

    /// 消息区翻页步长（按实际可见行数）
    fn messagePageRows(self: *AppState) usize {
        return if (self.message_visible_rows > 0) self.message_visible_rows else 10;
    }

    /// 右上角临时悬浮通知（2 秒）
    fn setToast(self: *AppState, text: []const u8) void {
        const n = @min(text.len, self.toast.len);
        @memcpy(self.toast[0..n], text[0..n]);
        self.toast_len = n;
        const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        self.toast_until_ms = now + 2000;
    }

    /// 屏幕坐标 → 内容位置（严格命中：仅当 y 落在有文本的渲染行上）
    fn pointFromScreenStrict(self: *AppState, x: u16, y: u16) ?SelPoint {
        for (self.sel_rows[0..self.sel_row_count]) |*row| {
            if (row.y != y) continue;
            if (!rowSegmentsLive(self, row)) return null; // 陈旧行（内容已重分配）：视为无文本
            // 该行无文本（如分隔线）：取下方最近的有文本行
            if (pointInRow(row, x)) |p| return p;
            return null;
        }
        return null;
    }

    /// 屏幕坐标 → 内容位置（基于当前帧的行映射；没有映射的行取垂直距离最近的文本行）
    fn pointFromScreen(self: *AppState, x: u16, y: u16) ?SelPoint {
        const rows = self.sel_rows[0..self.sel_row_count];
        if (rows.len == 0) return null;

        // 精确命中该屏幕行
        for (rows, 0..) |*row, i| {
            if (row.y != y) continue;
            if (rowSegmentsLive(self, row)) {
                if (pointInRow(row, x)) |p| return p;
            }
            // 该行无文本（如分隔线）：优先取下方最近的有文本行
            for (rows[i + 1 ..]) |*next| {
                if (!rowSegmentsLive(self, next)) continue;
                if (pointInRow(next, x)) |p| return p;
            }
            var j = i;
            while (j > 0) {
                j -= 1;
                if (!rowSegmentsLive(self, &rows[j])) continue;
                if (pointInRow(&rows[j], x)) |p| return p;
            }
            return null;
        }

        // 光标落在没有映射的行（思考块头/空行等）或区域之外：
        // 取垂直距离最近的有文本行（同距优先下方），避免端点跳到远端
        var below: ?SelPoint = null;
        var below_dist: usize = 0;
        for (rows) |*row| {
            if (row.y < y) continue;
            if (!rowSegmentsLive(self, row)) continue;
            if (pointInRow(row, x)) |p| {
                below = p;
                below_dist = @as(usize, row.y) - y;
                break;
            }
        }
        var above: ?SelPoint = null;
        var above_dist: usize = 0;
        var j = rows.len;
        while (j > 0) {
            j -= 1;
            const row = &rows[j];
            if (row.y > y) continue;
            if (!rowSegmentsLive(self, row)) continue;
            if (pointInRow(row, x)) |p| {
                above = p;
                above_dist = @as(usize, y) - row.y;
                break;
            }
        }
        if (below) |p| {
            if (above == null or below_dist <= above_dist) return p;
        }
        return above;
    }

    /// 屏幕坐标 → 输入框内容位置（严格命中可视行）
    fn pointFromInputStrict(self: *AppState, x: u16, y: u16) ?SelPoint {
        for (self.input_sel_rows[0..self.input_sel_row_count]) |row| {
            if (row.y != y) continue;
            const text = self.input.value();
            return .{ .off = offsetInRange(text, row.start, row.end, x -| row.x) };
        }
        return null;
    }

    /// 屏幕坐标 → 输入框内容位置（垂直方向夹取到首/末可视行）
    fn pointFromInputClamped(self: *AppState, x: u16, y: u16) ?SelPoint {
        const rows = self.input_sel_rows[0..self.input_sel_row_count];
        if (rows.len == 0) return null;
        var row: InputSelRow = undefined;
        if (y <= rows[0].y) {
            row = rows[0];
        } else if (y >= rows[rows.len - 1].y) {
            row = rows[rows.len - 1];
        } else {
            for (rows) |r| {
                if (r.y == y) {
                    row = r;
                    break;
                }
            }
        }
        const text = self.input.value();
        return .{ .off = offsetInRange(text, row.start, row.end, x -| row.x) };
    }

    /// 输入框选区的字节范围 [lo, hi)；无有效选区返回 null
    fn inputSelectionRange(self: *AppState) ?[2]usize {
        if (!self.sel_active or self.sel_area != .input) return null;
        const text = self.input.value();
        const a = @min(self.sel_anchor.off, text.len);
        const b = @min(self.sel_current.off, text.len);
        const lo = @min(a, b);
        const hi = @max(a, b);
        if (hi <= lo) return null;
        return .{ lo, hi };
    }

    /// 删除输入框选中内容（无选区时无操作）
    fn deleteInputSelection(self: *AppState) void {
        if (self.inputSelectionRange()) |r| {
            self.input.deleteRange(r[0], r[1]);
            self.clearSelection();
        }
    }

    /// 全选输入框文本
    fn selectAllInput(self: *AppState) void {
        const text = self.input.value();
        if (text.len == 0) {
            self.clearSelection();
            return;
        }
        self.sel_area = .input;
        self.sel_anchor = .{ .off = 0 };
        self.sel_current = .{ .off = text.len };
        self.sel_active = true;
        self.sel_dragging = false;
        self.auto_scroll_dir = 0;
    }

    /// 复制选中内容到剪贴板
    fn copySelection(self: *AppState) void {
        if (!self.sel_active) return;

        if (self.sel_area == .input) {
            const text = self.input.value();
            const sel = extractInputSelection(text, self.sel_anchor.off, self.sel_current.off);
            if (sel.len == 0) {
                self.clearSelection();
                return;
            }
            if (clipboard.setText(self.allocator, sel)) {
                var note_buf: [64]u8 = undefined;
                const note = std.fmt.bufPrint(&note_buf, "已复制 {d} 字符", .{sel.len}) catch "已复制";
                self.setToast(note);
            } else {
                self.setToast("复制到剪贴板失败");
            }
            self.clearSelection();
            return;
        }

        const contents = self.allocator.alloc([]const u8, self.messages.items.len) catch return;
        defer self.allocator.free(contents);
        const reasonings = self.allocator.alloc([]const u8, self.messages.items.len) catch return;
        defer self.allocator.free(reasonings);
        for (self.messages.items, 0..) |m, i| {
            contents[i] = m.content;
            reasonings[i] = if (m.reasoning) |r| r else "";
        }

        const text = extractSelectionText(self.allocator, contents, reasonings, self.sel_anchor, self.sel_current) catch return;
        defer self.allocator.free(text);

        if (text.len == 0) {
            self.clearSelection();
            return;
        }

        // 选区可能覆盖历史脏字节：复制前清洗为合法 UTF-8
        var copy_text: []const u8 = text;
        var clean: ?[]u8 = null;
        if (!std.unicode.utf8ValidateSlice(text)) {
            clean = ai.sanitizeUtf8(self.allocator, text) catch null;
            if (clean) |c| copy_text = c;
        }
        defer if (clean) |c| self.allocator.free(c);

        if (clipboard.setText(self.allocator, copy_text)) {
            var note_buf: [64]u8 = undefined;
            const note = std.fmt.bufPrint(&note_buf, "已复制 {d} 字符", .{copy_text.len}) catch "已复制";
            self.setToast(note);
        } else {
            self.setToast("复制到剪贴板失败");
        }
        self.clearSelection();
    }

    /// 剪切输入框选中内容到剪贴板（消息区为只读，不剪切）
    fn cutSelection(self: *AppState) void {
        _ = self.cutSelectionWith(clipboard.setText);
    }

    /// 剪切实现：先写剪贴板，成功后再删除选中文本（失败则原文与选区保留，避免丢数据）。
    /// write 可注入以便单测（生产环境为 clipboard.setText）
    fn cutSelectionWith(self: *AppState, write: ClipboardWriter) bool {
        const r = self.inputSelectionRange() orelse return false;
        const text = self.input.value();
        const sel = text[r[0]..r[1]];
        if (!write(self.allocator, sel)) {
            self.setToast("剪切到剪贴板失败");
            return false;
        }
        var note_buf: [64]u8 = undefined;
        const note = std.fmt.bufPrint(&note_buf, "已剪切 {d} 字符", .{sel.len}) catch "已剪切";
        self.setToast(note);
        self.input.deleteRange(r[0], r[1]);
        self.clearSelection();
        return true;
    }

    fn clearHistory(self: *AppState) void {
        for (self.history.items) |msg| {
            freeMessage(self.allocator, msg);
        }
        self.history.clearRetainingCapacity();
        // 历史整体更换：usage 锚点失效
        self.usage_anchor_len = null;
        self.usage_anchor_tokens = 0;
    }

    /// 把数据库中的消息灌入内存历史与界面显示（无 checkpoint 版本）
    fn applyLoadedMessages(self: *AppState, rows: []const db_mod.MessageRow) void {
        self.applyLoadedMessagesWithCheckpoint(rows, null, true);
    }

    /// 把数据库中的消息灌入内存历史与界面显示
    /// - system：升级为当前 system_prompt（并更新库内旧值）
    /// - 有 checkpoint：历史重建为 system + 摘要伪消息 + 保留区
    /// - assistant/tool：恢复工具调用字段与提示行
    fn applyLoadedMessagesWithCheckpoint(
        self: *AppState,
        rows: []const db_mod.MessageRow,
        checkpoint: ?db_mod.CompactionRow,
        with_display: bool,
    ) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // 工具调用索引：id → 名称/参数（在 tool 行重建工具块时需要参数生成标题）
        const CallIdx = struct { id: []const u8, name: []const u8, arguments: []const u8 };
        var call_idx = std.ArrayListUnmanaged(CallIdx){ .items = &.{}, .capacity = 0 };
        defer call_idx.deinit(arena);

        // 非块工具的调用行消息下标：id → msg_idx（结果到达后回填大小统计）
        const CallLineIdx = struct { id: []const u8, msg_idx: usize };
        var call_lines = std.ArrayListUnmanaged(CallLineIdx){ .items = &.{}, .capacity = 0 };
        defer call_lines.deinit(arena);

        // system prompt 升级（历史里只保留一份）
        for (rows) |row| {
            if (!std.mem.eql(u8, row.role, "system")) continue;
            if (!std.mem.eql(u8, row.content, system_prompt)) {
                if (self.db) |*db| db.updateMessageContent(row.id, system_prompt) catch {};
            }
            break;
        }
        // 摘要文本：优先取 role='summary' 的消息行；旧记录回退到 compaction.summary
        var summary_text: []const u8 = "";
        var summary_msg_id: i64 = 0;
        var compacted_count: usize = 0;
        if (checkpoint) |cp| {
            summary_msg_id = cp.summary_message_id;
            if (summary_msg_id != 0) {
                for (rows) |row| {
                    if (row.id == summary_msg_id) {
                        summary_text = row.content;
                        break;
                    }
                }
            }
            if (summary_text.len == 0) summary_text = cp.summary;
            for (rows) |row| {
                if (!std.mem.eql(u8, row.role, "system") and row.id < cp.tail_start_id) compacted_count += 1;
            }
        }

        if (checkpoint != null) {
            // 被压缩区不再发送：历史 = system + 摘要 + 保留区
            self.appendHistory("system", system_prompt);
            self.appendCheckpointHistory(summary_text);
        }

        // 注意：历史只收保留区（id >= tail_start_id），但**显示始终保留全部消息**，
        // 这样用户仍能往上滚动查看被压缩的历史。
        var marker_shown = checkpoint == null;
        for (rows) |row| {
            if (row.id > self.last_seen_msg_id) self.last_seen_msg_id = row.id;
            // 摘要消息行在显示上由边界气泡代替（避免出现在末尾）
            if (summary_msg_id != 0 and row.id == summary_msg_id) continue;

            const in_tail = checkpoint == null or row.id >= checkpoint.?.tail_start_id;
            if (!marker_shown and in_tail) {
                if (with_display) self.appendCheckpointDisplay(summary_text, compacted_count, checkpoint.?);
                marker_shown = true;
            }

            if (std.mem.eql(u8, row.role, "system")) {
                if (checkpoint == null) {
                    self.appendHistoryMessage(.{ .role = "system", .content = system_prompt });
                }
                continue;
            }

            if (std.mem.eql(u8, row.role, "tool")) {
                if (in_tail) {
                    self.appendHistoryMessage(.{
                        .role = "tool",
                        .content = row.content,
                        .tool_call_id = row.tool_call_id,
                        .db_id = row.id,
                    });
                }
                // 找到对应的调用（优先用落库的工具名，参数从调用索引取）
                var name: []const u8 = row.tool_name;
                var args: []const u8 = "";
                var line_idx: ?usize = null;
                for (call_idx.items) |ci| {
                    if (std.mem.eql(u8, ci.id, row.tool_call_id)) {
                        args = ci.arguments;
                        if (name.len == 0) name = ci.name;
                        break;
                    }
                }
                // 增量刷新时，调用可能在本批次之外：从已有历史里找对应调用
                if (args.len == 0) {
                    for (self.history.items) |hm| {
                        if (hm.tool_calls) |cs| {
                            for (cs) |c| {
                                if (std.mem.eql(u8, c.id, row.tool_call_id)) {
                                    args = c.arguments;
                                    if (name.len == 0) name = c.name;
                                    break;
                                }
                            }
                        }
                    }
                }
                for (call_lines.items) |cl| {
                    if (std.mem.eql(u8, cl.id, row.tool_call_id)) {
                        line_idx = cl.msg_idx;
                        break;
                    }
                }
                if (with_display) addLoadedToolDisplay(self, arena, name, args, line_idx, row);
                continue;
            }

            if (std.mem.eql(u8, row.role, "assistant")) {
                const calls = parseToolCalls(arena, row.tool_calls);
                if (in_tail) {
                    self.appendHistoryMessage(.{
                        .role = "assistant",
                        .content = row.content,
                        .tool_calls = calls,
                        .db_id = row.id,
                    });
                }
                // 先恢复正文，再补工具提示行/块（与实时渲染顺序一致）
                if (with_display) self.addLoadedAssistantMessage(row.content, row.reasoning, row.reasoning_ms);
                if (calls) |cs| {
                    for (cs) |c| {
                        call_idx.append(arena, .{ .id = c.id, .name = c.name, .arguments = c.arguments }) catch {};
                        // 块类工具（bash/edit）在对应的 tool 行重建；其余在此出一行提示
                        if (toolBlockKind(c.name) == null) {
                            if (with_display) addLoadedToolCallNote(self, arena, c.name, c.arguments);
                            if (with_display and self.messages.items.len > 0) {
                                call_lines.append(arena, .{ .id = c.id, .msg_idx = self.messages.items.len - 1 }) catch {};
                            }
                        }
                    }
                }
                continue;
            }

            // user 及其他角色
            if (in_tail) {
                self.appendHistoryMessage(.{ .role = row.role, .content = row.content, .db_id = row.id });
            }
            if (with_display and std.mem.eql(u8, row.role, "user")) {
                self.addUserMessage(row.content);
            }
        }

        // 恢复长会话时先批量折叠较早的工具输出，避免第一轮就把整段历史发给模型
        _ = self.maybeFoldOldToolOutputs();

        // 加载会话后立即用历史估算上下文占用（无需等一轮对话）
        self.refreshEstimatedUsage();
    }

    /// 从数据库恢复的 AI 回复（Markdown + 思考块，思考块默认折叠）
    fn addLoadedAssistantMessage(self: *AppState, content: []const u8, reasoning: []const u8, reasoning_ms: i64) void {
        // 纯工具调用轮（无正文也无思考）没有可显示内容：不创建空消息，否则 0 行消息
        // 会让相邻消息的间隔叠成两个空行（实时路径对这类回合也不会创建显示消息）
        if (content.len == 0 and reasoning.len == 0) return;

        const owned_content: []const u8 = if (content.len > 0)
            (self.allocator.dupe(u8, content) catch return)
        else
            "";
        var parsed: ?[]md_mod.Line = null;
        if (content.len > 0) {
            parsed = md_mod.parse(self.allocator, owned_content, md_mod.default_styles) catch null;
        }
        var owned_reasoning: ?[]u8 = null;
        if (reasoning.len > 0) {
            owned_reasoning = self.allocator.dupe(u8, reasoning) catch null;
        }
        self.messages.append(self.allocator, .{
            .content = owned_content,
            .style = .{ .fg = .white },
            .md = parsed,
            .reasoning = owned_reasoning,
            .reasoning_ms = reasoning_ms,
        }) catch {
            if (owned_content.len > 0) self.allocator.free(owned_content);
            if (parsed) |md| md_mod.free(self.allocator, md);
            if (owned_reasoning) |r| self.allocator.free(r);
            return;
        };
        self.scroll_offset = 0;
    }

    /// 加载会话内容（含 compaction checkpoint；会清空当前历史/显示）
    fn loadSessionContent(self: *AppState, session_id: i64) void {
        const db = if (self.db) |*d| d else return;
        const rows = db.loadMessages(session_id) catch {
            self.addMessage("加载会话失败", .{ .fg = .red });
            return;
        };
        self.clearHistory();
        self.clearDisplay();
        self.clearSelection();
        self.clearPendingSends();
        self.session_id = session_id;
        // 记录"上次访问"：下次启动时自动恢复该会话
        db.touchSession(session_id) catch {};
        self.last_seen_msg_id = 0;
        const checkpoint = db.latestCompaction(session_id) catch null;
        self.last_compaction_id = if (checkpoint) |c| c.id else 0;
        if (rows.len == 0 and checkpoint == null) {
            self.appendHistory("system", system_prompt);
            return;
        }
        self.applyLoadedMessagesWithCheckpoint(rows, checkpoint, true);
    }

    /// 仅重建内存历史（不动显示）：工具循环中途压缩后让主线程与 DB 对齐
    fn rebuildHistoryFromDb(self: *AppState) void {
        const db = if (self.db) |*d| d else return;
        const rows = db.loadMessages(self.session_id) catch return;
        const checkpoint = db.latestCompaction(self.session_id) catch null;
        self.clearHistory();
        self.last_seen_msg_id = 0;
        self.last_compaction_id = if (checkpoint) |c| c.id else 0;
        self.applyLoadedMessagesWithCheckpoint(rows, checkpoint, false);
    }

    /// 把压缩摘要作为历史中的 checkpoint 伪消息（user 角色，内容固定利于缓存稳定）
    fn appendCheckpointHistory(self: *AppState, summary: []const u8) void {
        const wrapper = std.fmt.allocPrint(
            self.allocator,
            "<conversation-checkpoint>\n（更早的对话已压缩，以下为摘要；需要细节时读取相关文件或询问用户）\n{s}\n</conversation-checkpoint>",
            .{summary},
        ) catch return;
        defer self.allocator.free(wrapper);
        self.appendHistoryMessage(.{ .role = "user", .content = wrapper });
    }

    /// 界面上显示压缩边界气泡：黄色标题 + 摘要正文（可像普通对话一样回看；不进历史）
    fn appendCheckpointDisplay(
        self: *AppState,
        summary: []const u8,
        compacted_count: usize,
        cp: db_mod.CompactionRow,
    ) void {
        var buf: [256]u8 = undefined;
        const header = formatCompactionNotice(
            &buf,
            compacted_count,
            summary.len,
            @intCast(@max(cp.tokens_before, 0)),
        );
        self.addMessage(header, .{ .fg = .yellow });
        if (summary.len > 0) {
            self.addMessageImpl(summary, .{}, true, false);
        }
    }

    /// 切换到指定会话（生成中禁止，避免历史/显示被并发修改）
    fn loadSessionById(self: *AppState, session_id: i64) void {
        if (self.streamStatus() != .idle) return;
        self.loadSessionContent(session_id);
    }

    /// 新建会话（生成中禁止）
    fn newSession(self: *AppState) void {
        if (self.streamStatus() != .idle) return;
        const db = if (self.db) |*d| d else return;
        self.clearHistory();
        self.clearDisplay();
        self.clearPendingSends();
        self.last_seen_msg_id = 0;
        const sid = db.createSession("") catch {
            self.addMessage("新建会话失败", .{ .fg = .red });
            return;
        };
        self.session_id = sid;
        const sys_id = db.insertMessage(.{ .session_id = sid, .role = "system", .content = system_prompt }) catch 0;
        if (sys_id > self.last_seen_msg_id) self.last_seen_msg_id = sys_id;
        self.appendHistory("system", system_prompt);
        self.refreshEstimatedUsage();
    }

    fn handleInput(self: *AppState, input: []const u8) void {
        if (input.len == 0) return;

        // 仅当首词是已知指令时才按指令处理，否则一律发给 AI
        if (isCommandInput(input)) {
            self.handleCommand(input[1..]);
        } else {
            self.askAI(input);
        }
    }

    fn handleCommand(self: *AppState, command: []const u8) void {
        const name = firstToken(command);
        if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "?") or std.mem.eql(u8, name, "h")) {
            self.menu_parent = null;
            self.help_select_index = 0;
            self.mode = .help_select;
        } else if (std.mem.eql(u8, name, "models")) {
            self.menu_parent = null;
            self.model_select_index = 0;
            self.mode = .model_select;
        } else if (std.mem.eql(u8, name, "sessions")) {
            self.openSessionSelect(null);
        } else if (std.mem.eql(u8, name, "compact")) {
            const rest = std.mem.trim(u8, command[name.len..], " \t");
            const keep = std.fmt.parseInt(usize, rest, 10) catch 0;
            self.runCompactCommand(keep);
        } else if (std.mem.eql(u8, name, "thinking")) {
            const rest = std.mem.trim(u8, command[name.len..], " \t");
            if (rest.len == 0) {
                self.openThinkingSelect(null);
            } else if (isThinkingLevel(rest)) {
                self.applyThinking(rest, true);
            } else {
                self.addMessage("思考强度可选: off / low / high / max", .{ .fg = .red });
            }
        } else if (std.mem.eql(u8, name, "exit")) {
            self.running = false;
        } else if (name.len > 0) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "未知指令: /{s} (输入 /help 查看帮助)", .{name}) catch return;
            self.addMessage(msg, .{ .fg = .red });
        }
    }

    /// 关闭当前菜单：有父菜单则返回上一级，否则回到主界面
    fn closeMenu(self: *AppState) void {
        if (self.menu_parent) |p| {
            self.mode = p;
            self.menu_parent = null;
        } else {
            self.mode = .normal;
        }
    }

    /// 手动压缩：先按默认保留窗口选区间，没命中再按历史字节逐级缩小
    /// （纯计算，不发请求；返回选定的保留 token 数）
    fn chooseCompactionKeep(self: *AppState, keep_override: usize) ?usize {
        if (keep_override > 0) {
            return if (selectCompactionRange(self.history.items, keep_override * 4) != null) keep_override else null;
        }
        if (self.keep_recent_tokens > 0 and
            selectCompactionRange(self.history.items, self.keep_recent_tokens * 4) != null)
        {
            return self.keep_recent_tokens;
        }
        const hist_bytes = historyRequestBytesSlice(self.history.items);
        const fractions = [_]usize{ 2, 4, 8, 16, 32 };
        for (fractions) |f| {
            const k = hist_bytes / f / 4;
            if (k == 0) break;
            if (selectCompactionRange(self.history.items, k * 4) != null) return k;
        }
        return null;
    }

    fn runCompactionAdaptive(self: *AppState) CompactionOutcome {
        const keep = self.chooseCompactionKeep(0) orelse return CompactionOutcome{};
        return self.runCompaction(keep);
    }

    /// 手动压缩当前会话（TUI `/compact [保留token]` 与帮助菜单共用）：异步 + 摘要流式
    fn runCompactCommand(self: *AppState, keep_tokens: usize) void {
        self.startCompaction(keep_tokens);
    }

    /// 应用思考强度（persist=true 时写入 config.json；测试用 false）。
    /// 右上角弹一个 2 秒的悬浮通知。
    fn applyThinking(self: *AppState, value: []const u8, persist: bool) void {
        self.config.setThinking(self.allocator, value);
        if (persist) self.config.save(self.io, self.allocator);
        var buf: [64]u8 = undefined;
        const label = if (value.len == 0) "未设置" else value;
        if (std.fmt.bufPrint(&buf, "思考强度: {s}", .{label})) |msg| {
            self.setToast(msg);
        } else |_| {}
    }

    /// 打开思考强度选单（parent 非空时 Esc 返回该菜单）
    fn openThinkingSelect(self: *AppState, parent: ?Mode) void {
        const levels = thinkingLevelsFor(self.currentModel());
        self.thinking_select_index = 0;
        for (levels, 0..) |lv, i| {
            if (std.mem.eql(u8, lv, self.config.thinking)) {
                self.thinking_select_index = i;
                break;
            }
        }
        self.menu_parent = parent;
        self.mode = .thinking_select;
    }

    fn handleThinkingSelectKey(self: *AppState, key: tui.KeyEvent) void {
        const levels = thinkingLevelsFor(self.currentModel());
        const total = levels.len;
        switch (key.code) {
            .up => {
                self.thinking_select_index = if (self.thinking_select_index == 0) total - 1 else self.thinking_select_index - 1;
            },
            .down => {
                self.thinking_select_index = if (self.thinking_select_index + 1 >= total) 0 else self.thinking_select_index + 1;
            },
            .enter => {
                if (self.thinking_select_index < total) {
                    self.applyThinking(levels[self.thinking_select_index], true);
                }
                self.mode = .normal;
                self.menu_parent = null;
            },
            .esc => self.closeMenu(),
            else => {},
        }
    }

    fn isCompacting(self: *AppState) bool {
        return self.compact_status.load(.acquire) == 1;
    }

    /// 构造异步压缩计划（历史深拷贝，供 worker 线程独占）
    fn buildCompactionPlan(
        self: *AppState,
        provider: *const config_mod.Provider,
        model: []const u8,
        keep: usize,
    ) !*CompactionPlan {
        const plan = try self.allocator.create(CompactionPlan);
        errdefer self.allocator.destroy(plan);
        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        plan.* = .{
            .app = self,
            .arena = arena_ptr,
            .io = self.io,
            .async = true,
            .session_id = self.session_id,
            .behavior = config_mod.behavior(provider),
            .environ_map = self.environ_map,
            .keep_tokens = keep,
        };
        errdefer plan.arena.deinit();
        const arena = plan.arena.allocator();
        // worker 自建连接时用实际打开的库路径（测试/CLI 可能不是默认路径）
        const db_path: []const u8 = if (self.db) |*d| d.path else self.db_path;
        plan.db_path = try arena.dupeZ(u8, db_path);
        plan.endpoint = try arena.dupe(u8, provider.endpoint);
        plan.api_key = try arena.dupe(u8, self.resolvedApiKey(provider));
        plan.model = try arena.dupe(u8, model);
        plan.provider_name = try arena.dupe(u8, provider.name);
        plan.history = try arena.alloc(ai.Message, self.history.items.len);
        for (self.history.items, 0..) |m, i| {
            plan.history[i] = try cloneMessage(arena, m);
        }
        return plan;
    }

    /// 启动异步压缩：预选区间（纯计算）→ 快照历史 → worker 流式产出摘要
    fn startCompaction(self: *AppState, keep_override: usize) void {
        if (self.isStreaming()) {
            self.addMessage("生成中，无法压缩上下文", .{ .fg = .red });
            return;
        }
        if (self.isCompacting()) {
            self.addMessage("压缩已在进行中", .{ .fg = .dark_gray });
            return;
        }
        const provider = self.currentProvider() orelse {
            self.addMessage("无可用提供商", .{ .fg = .red });
            return;
        };
        const model = self.currentModel();
        if (model.len == 0) {
            self.addMessage("未选择模型", .{ .fg = .red });
            return;
        }
        if (self.db == null) {
            self.addMessage("数据库不可用", .{ .fg = .red });
            return;
        }
        const keep = self.chooseCompactionKeep(keep_override) orelse {
            self.addMessage("当前内容无需压缩", .{ .fg = .dark_gray });
            return;
        };
        const plan = self.buildCompactionPlan(provider, model, keep) catch {
            self.addMessage("内存分配失败", .{ .fg = .red });
            return;
        };

        self.compact_cancel.store(false, .release);
        self.compact_mutex.lockUncancelable(self.io);
        self.compact_buf.clearRetainingCapacity();
        self.compact_consume_pos = 0;
        self.compact_mutex.unlock(self.io);
        self.compact_head_idx = null;
        self.compact_msg_idx = null;
        self.compact_plan = plan;
        self.compact_status.store(1, .release);
        self.compact_thread = std.Thread.spawn(.{}, compactionWorker, .{plan}) catch {
            self.compact_status.store(0, .release);
            self.compact_plan = null;
            plan.deinit();
            self.addMessage("创建压缩线程失败", .{ .fg = .red });
            return;
        };
    }

    /// 主循环泵：消费摘要增量 + 结束收尾
    fn pumpCompaction(self: *AppState) void {
        if (self.compact_status.load(.acquire) == 0) return;
        var delta: ?[]u8 = null;
        self.compact_mutex.lockUncancelable(self.io);
        if (self.compact_buf.items.len > self.compact_consume_pos) {
            const slice = self.compact_buf.items[self.compact_consume_pos..];
            if (self.allocator.dupe(u8, slice)) |copy| {
                delta = copy;
                self.compact_consume_pos = self.compact_buf.items.len;
            } else |_| {}
        }
        self.compact_mutex.unlock(self.io);
        if (delta) |d| {
            self.appendCompactChunk(d);
            self.allocator.free(d);
        }
        if (self.compact_status.load(.acquire) == 2) {
            self.finalizeCompaction();
            // 压缩期间排队的消息：压缩收尾后作为新回合发出
            self.flushPendingSends();
        }
    }

    /// 摘要增量追加（首块时先放黄色标题，再建正文消息）
    fn appendCompactChunk(self: *AppState, chunk: []const u8) void {
        if (self.compact_msg_idx == null) {
            self.addMessage("▣ 正在压缩上下文…", .{ .fg = .yellow });
            self.compact_head_idx = if (self.messages.items.len > 0) self.messages.items.len - 1 else null;
            self.messages.append(self.allocator, .{ .content = "", .style = .{ .fg = .white } }) catch return;
            self.compact_msg_idx = self.messages.items.len - 1;
        }
        const idx = self.compact_msg_idx.?;
        const msg = &self.messages.items[idx];
        const width = self.message_wrap_width;
        const rows_before = if (width > 0) messageRowCount(msg.*, width) else 0;

        const joined = self.allocator.alloc(u8, msg.content.len + chunk.len) catch return;
        @memcpy(joined[0..msg.content.len], msg.content);
        @memcpy(joined[msg.content.len..], chunk);
        if (msg.content.len > 0) self.allocator.free(msg.content);
        msg.content = joined;
        if (msg.md) |old| md_mod.free(self.allocator, old);
        msg.md = md_mod.parse(self.allocator, joined, md_mod.default_styles) catch null;

        if (width > 0) {
            const rows_after = messageRowCount(msg.*, width);
            const added = rows_after -| rows_before;
            if (self.scroll_offset > 0 and added > 0) self.scroll_offset +|= added;
        }
    }

    /// 替换一条显示消息的内容与样式（用于把"正在压缩…"标题换成结果）
    fn replaceDisplayMessage(self: *AppState, idx: usize, content: []const u8, style: Style) void {
        if (idx >= self.messages.items.len) return;
        const msg = &self.messages.items[idx];
        const owned = self.allocator.dupe(u8, content) catch return;
        if (msg.content.len > 0) self.allocator.free(msg.content);
        if (msg.md) |old| md_mod.free(self.allocator, old);
        msg.content = owned;
        msg.md = null;
        msg.style = style;
    }

    /// 异步压缩收尾：join、替换标题、按需重建历史（显示保持流式结果）
    fn finalizeCompaction(self: *AppState) void {
        if (self.compact_thread) |t| {
            t.join();
            self.compact_thread = null;
        }
        const plan = self.compact_plan orelse {
            self.compact_status.store(0, .release);
            return;
        };
        self.compact_plan = null;
        defer plan.deinit();

        if (plan.err) |e| {
            if (std.mem.eql(u8, e, "已取消")) {
                if (self.compact_head_idx) |idx| {
                    self.replaceDisplayMessage(idx, "▣ 压缩已取消", .{ .fg = .dark_gray });
                }
            } else {
                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "▣ 压缩失败: {s}", .{e}) catch "▣ 压缩失败";
                if (self.compact_head_idx) |idx| {
                    self.replaceDisplayMessage(idx, text, .{ .fg = .red });
                }
                const detail = plan.err_detail_buf[0..plan.err_detail_len];
                if (detail.len > 0) {
                    var dbuf: [320]u8 = undefined;
                    const dmsg = std.fmt.bufPrint(&dbuf, "服务端返回: {s}", .{detail}) catch "";
                    if (dmsg.len > 0) self.addMessage(dmsg, .{ .fg = .dark_gray });
                }
            }
        } else if (plan.compacted) {
            var buf: [256]u8 = undefined;
            const text = formatCompactionNotice(&buf, plan.summarized, plan.summary_len, plan.tokens_before);
            if (self.compact_head_idx) |idx| {
                self.replaceDisplayMessage(idx, text, .{ .fg = .yellow });
            }
            self.last_usage = .{};
            self.context_usage = .{};
            self.rebuildHistoryFromDb();
            self.last_compaction_id = if (self.db) |*db|
                (if (db.latestCompaction(self.session_id) catch null) |cp| cp.id else self.last_compaction_id)
            else
                self.last_compaction_id;
        } else {
            if (self.compact_head_idx) |idx| {
                self.replaceDisplayMessage(idx, "当前内容无需压缩", .{ .fg = .dark_gray });
            }
        }

        self.compact_mutex.lockUncancelable(self.io);
        self.compact_buf.clearRetainingCapacity();
        self.compact_consume_pos = 0;
        self.compact_mutex.unlock(self.io);
        self.compact_status.store(0, .release);
        self.compact_head_idx = null;
        self.compact_msg_idx = null;
    }

    fn executeHelpCommand(self: *AppState, name: []const u8) void {
        if (std.mem.eql(u8, name, "models")) {
            self.menu_parent = .help_select;
            self.model_select_index = 0;
            self.mode = .model_select;
        } else if (std.mem.eql(u8, name, "sessions")) {
            self.openSessionSelect(.help_select);
        } else if (std.mem.eql(u8, name, "compact")) {
            // 确认框：由用户确认后再执行（输入 /compact 仍直接执行）
            self.confirm_stage = 1;
            self.confirm_yes = false;
            self.mode = .compact_confirm;
        } else if (std.mem.eql(u8, name, "thinking")) {
            self.openThinkingSelect(.help_select);
        } else if (std.mem.eql(u8, name, "exit")) {
            self.running = false;
        } else {
            self.mode = .normal;
        }
    }

    fn handleHelpSelectKey(self: *AppState, key: tui.KeyEvent) void {
        const total = help_commands.len;
        switch (key.code) {
            .up => {
                // 首项再向上 → 跳到最后一项
                self.help_select_index = if (self.help_select_index == 0) total - 1 else self.help_select_index - 1;
            },
            .down => {
                // 末项再向下 → 跳到第一项
                self.help_select_index = if (self.help_select_index + 1 >= total) 0 else self.help_select_index + 1;
            },
            .enter => {
                self.executeHelpCommand(help_commands[self.help_select_index].name);
            },
            .esc => {
                self.closeMenu();
            },
            else => {},
        }
    }

    fn openSessionSelect(self: *AppState, parent: ?Mode) void {
        const db = if (self.db) |*d| d else {
            self.addMessage("数据库不可用，无法浏览会话", .{ .fg = .red });
            return;
        };
        const rows = db.listSessions() catch {
            self.addMessage("加载会话列表失败", .{ .fg = .red });
            return;
        };
        self.session_list = rows;

        // 光标定位到当前会话（列表第 0 项是"新建会话"）
        self.session_select_index = 0;
        for (rows, 0..) |s, i| {
            if (s.id == self.session_id) {
                self.session_select_index = i + 1;
                break;
            }
        }
        // 初始滚动位置：确保选中项可见
        const visible = if (self.menu_visible_rows > 0) self.menu_visible_rows else 10;
        self.session_view_start = if (self.session_select_index >= visible)
            self.session_select_index - visible + 1
        else
            0;
        self.menu_parent = parent;
        self.mode = .session_select;
    }

    fn handleSessionSelectKey(self: *AppState, key: tui.KeyEvent) void {
        const total = self.session_list.len + 1; // +1: 新建会话
        const visible = if (self.menu_visible_rows > 0) self.menu_visible_rows else 10;

        switch (key.code) {
            .up => {
                self.session_select_index = if (self.session_select_index == 0) total - 1 else self.session_select_index - 1;
                self.clampSessionViewStart(visible);
            },
            .down => {
                self.session_select_index = if (self.session_select_index + 1 >= total) 0 else self.session_select_index + 1;
                self.clampSessionViewStart(visible);
            },
            .enter => {
                if (self.session_select_index == 0) {
                    self.newSession();
                } else {
                    const s = self.session_list[self.session_select_index - 1];
                    self.loadSessionById(s.id);
                }
                self.menu_parent = null;
                self.mode = .normal;
            },
            .delete => {
                // 第一项"新建会话"不可删除
                if (self.session_select_index == 0) return;
                const s = self.session_list[self.session_select_index - 1];
                self.confirm_session_id = s.id;
                const copy_len = @min(s.title.len, self.confirm_title.len - 1);
                @memcpy(self.confirm_title[0..copy_len], s.title[0..copy_len]);
                self.confirm_title_len = copy_len;
                self.confirm_stage = 1;
                self.confirm_yes = false; // 默认停在"否"
                self.mode = .session_confirm;
            },
            .esc => {
                self.closeMenu();
            },
            else => {},
        }
    }

    fn handleSessionConfirmKey(self: *AppState, key: tui.KeyEvent) void {
        switch (key.code) {
            .left, .right, .tab, .back_tab => {
                self.confirm_yes = !self.confirm_yes;
            },
            .enter => {
                if (!self.confirm_yes) {
                    // 选择"否" → 取消
                    self.confirm_stage = 0;
                    self.mode = .session_select;
                    return;
                }
                if (self.confirm_stage == 1) {
                    // 第一关通过，进入第二关（光标重新回到"否"）
                    self.confirm_stage = 2;
                    self.confirm_yes = false;
                } else {
                    self.deleteConfirmedSession();
                }
            },
            .esc => {
                self.confirm_stage = 0;
                self.mode = .session_select;
            },
            else => {},
        }
    }

    fn deleteConfirmedSession(self: *AppState) void {
        const db = if (self.db) |*d| d else return;
        const del_id = self.confirm_session_id;

        db.deleteSession(del_id) catch {
            self.addMessage("删除会话失败", .{ .fg = .red });
            self.confirm_stage = 0;
            self.mode = .session_select;
            return;
        };

        // 删除的是当前会话 → 切换到最近会话，没有则新建
        if (del_id == self.session_id) {
            const latest = db.latestSession() catch null;
            if (latest) |s| {
                self.loadSessionById(s.id);
            } else {
                self.newSession();
            }
        }

        // 刷新列表并修正光标
        self.session_list = db.listSessions() catch &.{};
        const total = self.session_list.len + 1;
        if (self.session_select_index >= total) {
            self.session_select_index = total - 1;
        }
        if (self.session_view_start > 0 and self.session_view_start >= total) {
            self.session_view_start = 0;
        }

        self.confirm_stage = 0;
        self.mode = .session_select;
    }

    /// 每个 SkyNet 会话的稳定路由标识（网关的 x-opencode-session /
    /// OpenAI 的 prompt_cache_key 都用它做缓存亲和）。
    /// 由会话 id 确定性派生：跨重启、切换会话后回来都不变，保证服务端前缀缓存可复用。
    fn sessionUuid(self: *AppState) []const u8 {
        if (!self.session_uuid_ready or self.session_uuid_for != self.session_id) {
            var seed_buf: [64]u8 = undefined;
            const seed = std.fmt.bufPrint(&seed_buf, "skynet:session:{d}", .{self.session_id}) catch "skynet:session:0";
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(seed, &hash, .{});
            const hex = std.fmt.bytesToHex(hash[0..16], .lower);
            @memcpy(self.session_uuid[0..8], hex[0..8]);
            self.session_uuid[8] = '-';
            @memcpy(self.session_uuid[9..13], hex[8..12]);
            self.session_uuid[13] = '-';
            @memcpy(self.session_uuid[14..18], hex[12..16]);
            self.session_uuid[18] = '-';
            @memcpy(self.session_uuid[19..23], hex[16..20]);
            self.session_uuid[23] = '-';
            @memcpy(self.session_uuid[24..36], hex[20..32]);
            self.session_uuid_ready = true;
            self.session_uuid_for = self.session_id;
        }
        return self.session_uuid[0..];
    }

    fn streamStatus(self: *AppState) StreamStatus {
        return @enumFromInt(self.stream_status.load(.acquire));
    }

    fn setStreamStatus(self: *AppState, s: StreamStatus) void {
        self.stream_status.store(@intFromEnum(s), .release);
    }

    fn isStreaming(self: *AppState) bool {
        return self.streamStatus() == .running;
    }

    /// Ctrl+Q：中断生成或压缩（worker 在下一块数据到达时退出）
    fn cancelStream(self: *AppState) void {
        if (self.isCompacting()) {
            self.compact_cancel.store(true, .release);
            return;
        }
        if (self.isStreaming()) self.stream_cancel.store(true, .release);
    }

    /// API Key：配置文件优先，为空时按 provider 指定的环境变量回退（Pi 风格）
    fn resolvedApiKey(self: *AppState, provider: *const config_mod.Provider) []const u8 {
        if (provider.api_key.len > 0) return provider.api_key;
        const env_name = provider.effectiveApiKeyEnv();
        if (env_name.len == 0) return "";
        const env = self.environ_map orelse return "";
        return env.get(env_name) orelse "";
    }

    fn createStreamJob(self: *AppState, provider: *const config_mod.Provider, model: []const u8) !*StreamJob {
        const allocator = self.allocator;
        const job = try allocator.create(StreamJob);
        errdefer allocator.destroy(job);
        job.app = self;
        job.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer job.arena.deinit();
        job.io = self.io;
        const arena = job.arena.allocator();
        job.cwd = try std.process.currentPathAlloc(self.io, arena);
        job.model = try arena.dupe(u8, model);
        job.endpoint = try arena.dupe(u8, provider.endpoint);
        job.api_key = try arena.dupe(u8, self.resolvedApiKey(provider));
        job.provider_name = try arena.dupe(u8, provider.name);
        job.session_id = try arena.dupe(u8, self.sessionUuid());
        job.behavior = config_mod.behavior(provider);
        // 思考强度是全局设置：拷进 job arena，避免主线程改动导致悬空
        job.behavior.reasoning_effort = try arena.dupe(u8, self.config.thinking);
        job.environ_map = self.environ_map;
        // worker 自建连接时用实际打开的库路径（测试/CLI 可能不是默认路径）
        const db_path: []const u8 = if (self.db) |*d| d.path else self.db_path;
        job.db_path = try arena.dupeZ(u8, db_path);
        job.session_id_num = self.session_id;
        job.auto_compact_pct = self.auto_compact_pct;
        job.context_window = self.contextWindowCurrent();
        job.keep_recent_tokens = self.keep_recent_tokens;
        // usage 锚点随历史拷进 job（增量估算用；越界时不使用）
        if (self.usage_anchor_len) |al| {
            if (al <= self.history.items.len) {
                job.anchor_len = al;
                job.anchor_tokens = self.usage_anchor_tokens;
            }
        }
        job.compacted_midturn = false;
        job.error_detail = "";
        job.usage_input = 0;
        job.usage_output = 0;
        job.usage_cached = 0;
        job.transcript = .{ .items = &.{}, .capacity = 0 };
        job.content = .{ .items = &.{}, .capacity = 0 };
        job.reasoning = .{ .items = &.{}, .capacity = 0 };
        job.reasoning_start_ms = 0;
        job.reasoning_end_ms = 0;
        job.tool_meta = .{ .items = &.{}, .capacity = 0 };
        job.history = try arena.alloc(ai.Message, self.history.items.len);
        for (self.history.items, 0..) |m, i| {
            job.history[i] = try cloneMessage(arena, m);
        }
        return job;
    }

    fn removeStreamingMessage(self: *AppState) void {
        if (self.streaming_msg_idx) |idx| {
            if (idx < self.messages.items.len) {
                const width = self.message_wrap_width;
                const rows = if (width > 0) messageRowCount(self.messages.items[idx], width) else 0;
                self.freeDisplayMessage(self.messages.items[idx]);
                _ = self.messages.orderedRemove(idx);
                // 反向补偿：移除的消息及其与上一条之间的间隔空行
                if (self.scroll_offset > 0) {
                    const sep: usize = if (idx > 0) 1 else 0;
                    self.scroll_offset -|= rows + sep;
                }
            }
            self.streaming_msg_idx = null;
        }
    }

    /// 一行式工具提示（非块渲染的工具，如 ls/read/grep）
    fn addToolNoteLine(self: *AppState, comptime fmt: []const u8, args: anytype, style: Style) void {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.addStreamMessage(line, style);
    }

    /// 向指定提示行追加后缀（工具结果统计，如 ` (3.0KB)`）
    fn appendNoteSuffixAt(self: *AppState, idx: usize, suffix: []const u8) void {
        if (suffix.len == 0) return;
        if (idx >= self.messages.items.len) return;
        const msg = &self.messages.items[idx];
        if (msg.tool_block != null or msg.md != null or msg.user) return;

        const width = self.message_wrap_width;
        const rows_before = if (width > 0) messageRowCount(msg.*, width) else 0;
        const joined = std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ msg.content, suffix }) catch return;
        if (msg.content.len > 0) self.allocator.free(msg.content);
        msg.content = joined;

        // 贴底时保持跟随；已上翻时补偿偏移，保持视口不动
        if (width > 0) {
            const rows_after = messageRowCount(msg.*, width);
            const added = rows_after -| rows_before;
            if (self.scroll_offset > 0 and added > 0) self.scroll_offset +|= added;
        }
    }

    /// 向最后一条提示行追加后缀（实时路径：调用行刚输出，结果随后到达）
    fn appendLastNoteSuffix(self: *AppState, suffix: []const u8) void {
        if (self.messages.items.len == 0) return;
        self.appendNoteSuffixAt(self.messages.items.len - 1, suffix);
    }

    /// 创建工具块消息（仅标题行）；成功返回 true
    fn beginToolBlock(self: *AppState, name: []const u8, args_json: []const u8, kind: ToolBlockKind) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const header = toolHeaderText(arena_state.allocator(), name, args_json) orelse return false;

        const owned = self.allocator.dupe(u8, header) catch return false;
        self.messages.append(self.allocator, .{
            .content = owned,
            .style = .{ .fg = .white },
            .tool_block = kind,
        }) catch {
            self.allocator.free(owned);
            return false;
        };
        self.preserveViewOnAppend();
        return true;
    }

    /// 向最近的工具块追加正文（bash 输出 / diff）；失败返回 false
    fn appendToolBlockBody(self: *AppState, kind: ToolBlockKind, body: []const u8, is_error: bool) bool {
        if (body.len == 0) return false;
        if (self.messages.items.len == 0) return false;
        const idx = self.messages.items.len - 1;
        const msg = &self.messages.items[idx];
        if (msg.tool_block == null or msg.tool_block.? != kind) return false;
        if (is_error) msg.tool_error = true;

        const width = self.message_wrap_width;
        const rows_before = if (width > 0) messageRowCount(msg.*, width) else 0;

        const max_lines: usize = if (kind == .diff) 40 else 20;
        const capped = capBlockBody(self.allocator, body, max_lines) catch return false;
        defer self.allocator.free(capped);

        const joined = std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ msg.content, capped }) catch return false;
        if (msg.content.len > 0) self.allocator.free(msg.content);
        msg.content = joined;

        // 贴底时保持跟随；已上翻时补偿偏移，保持视口不动
        if (width > 0) {
            const rows_after = messageRowCount(msg.*, width);
            const added = rows_after -| rows_before;
            if (self.scroll_offset > 0 and added > 0) self.scroll_offset +|= added;
        }
        return true;
    }

    fn askAI(self: *AppState, question: []const u8) void {
        // 生成中忽略发送
        if (self.isStreaming()) return;
        if (self.isCompacting()) {
            self.addMessage("正在压缩上下文，完成后再发送", .{ .fg = .dark_gray });
            return;
        }

        // 接近窗口阈值时先压缩（失败不阻塞对话；会重建历史/显示）
        self.maybeAutoCompact();

        const provider = self.currentProvider() orelse {
            self.addMessage("尚无可用提供商，输入 /models 后按 Ctrl+A 添加", .{ .fg = .red });
            return;
        };

        // 记录 user 消息（落库 + 内存历史）
        self.recordMessage("user", question, "", "", "", 0);

        // 快照请求参数与历史（工作线程独占）
        const job = self.createStreamJob(provider, self.currentModel()) catch {
            self.addMessage("内存分配失败", .{ .fg = .red });
            return;
        };
        self.stream_job = job;

        self.stream_mutex.lockUncancelable(self.io);
        self.stream_buf.clearRetainingCapacity();
        self.stream_consume_pos = 0;
        self.stream_reasoning_buf.clearRetainingCapacity();
        self.stream_reasoning_pos = 0;
        self.clearStreamEventsLocked();
        self.stream_mutex.unlock(self.io);
        self.streaming_msg_idx = null;
        self.scroll_offset = 0;
        self.stream_error = null;
        self.stream_cancel.store(false, .release);
        self.setStreamStatus(.running);

        self.stream_thread = std.Thread.spawn(.{}, streamWorker, .{job}) catch {
            self.setStreamStatus(.idle);
            job.deinit();
            self.stream_job = null;
            self.addMessage("创建请求线程失败", .{ .fg = .red });
            return;
        };
    }

    /// 生成/压缩期间用户提交消息：入队（稍后由 worker 注入或轮尾发出）+ 立即显示。
    /// 调用方负责清空输入框。
    fn queuePendingSend(self: *AppState, text: []const u8) void {
        if (text.len == 0) return;
        const owned = self.allocator.dupe(u8, text) catch {
            self.setToast("排队失败：内存不足");
            return;
        };
        self.pending_sends_mutex.lockUncancelable(self.io);
        if (self.pending_sends.items.len >= max_pending_sends) {
            self.pending_sends_mutex.unlock(self.io);
            self.allocator.free(owned);
            self.setToast("排队消息过多（上限 32 条），请稍候");
            return;
        }
        self.pending_sends.append(self.allocator, owned) catch {
            self.pending_sends_mutex.unlock(self.io);
            self.allocator.free(owned);
            self.setToast("排队失败：内存不足");
            return;
        };
        self.pending_sends_mutex.unlock(self.io);

        // 立即上屏；真正落库与送达发生在注入（工具轮次边界）或轮尾 flush
        self.addUserMessage(text);
        self.setToast("已排队：将在下一个工具轮次或本轮结束后发送");
    }

    /// 取走最早一条排队消息（无则 null；调用方负责释放）
    fn takeFirstPendingSend(self: *AppState) ?[]u8 {
        self.pending_sends_mutex.lockUncancelable(self.io);
        defer self.pending_sends_mutex.unlock(self.io);
        if (self.pending_sends.items.len == 0) return null;
        return self.pending_sends.orderedRemove(0);
    }

    /// 清空排队消息并释放文本（会话切换 / 退出清理）
    fn clearPendingSends(self: *AppState) void {
        self.pending_sends_mutex.lockUncancelable(self.io);
        defer self.pending_sends_mutex.unlock(self.io);
        for (self.pending_sends.items) |text| self.allocator.free(text);
        self.pending_sends.clearRetainingCapacity();
    }

    /// 一轮结束（正常/取消/失败）或压缩收尾后：若仍有排队消息，取最早一条作为新回合发出。
    /// 其余留在队列中，由下一回合的 worker 在工具轮次边界注入。
    fn flushPendingSends(self: *AppState) void {
        if (!self.running) return;
        if (self.isStreaming() or self.isCompacting()) return;
        if (self.currentProvider() == null) return; // 无可用提供商：保留队列，待配置就绪
        const text = self.takeFirstPendingSend() orelse return;
        defer self.allocator.free(text);
        self.askAI(text);
    }

    /// auto（硬编码）：思考结束后自动折叠正在流式的思考块。
    /// "思考结束"包括：正文开始、回合结束（工具轮）、整个请求收尾
    fn collapseStreamingThought(self: *AppState) void {
        const idx = self.streaming_msg_idx orelse return;
        if (idx >= self.messages.items.len) return;
        if (self.messages.items[idx].reasoning == null) return;
        setThoughtExpanded(self, idx, false, false);
    }

    /// 当前回合结束：保留有内容的消息，丢弃空回合
    fn closeCurrentTurn(self: *AppState) void {
        self.collapseStreamingThought();
        if (self.streaming_msg_idx) |idx| {
            if (idx < self.messages.items.len) {
                const msg = &self.messages.items[idx];
                if (msg.content.len == 0 and msg.reasoning == null) {
                    self.removeStreamingMessage();
                    return;
                }
            }
            self.streaming_msg_idx = null;
        }
    }

    /// 确保存在进行中的 assistant 消息（工具轮之间会重新创建）
    fn ensureStreamingMessage(self: *AppState) ?usize {
        if (self.streaming_msg_idx) |idx| {
            if (idx < self.messages.items.len) return idx;
        }
        self.messages.append(self.allocator, .{
            .content = "",
            .style = .{ .fg = .white },
            .md = null,
        }) catch return null;
        const idx = self.messages.items.len - 1;
        self.streaming_msg_idx = idx;
        // 新建空消息同样会多出消息间隔空行：上翻阅读时保持视口不动
        self.preserveViewOnAppend();
        return idx;
    }

    fn clearStreamEventsLocked(self: *AppState) void {
        for (self.stream_events.items) |ev| {
            if (ev.name.len > 0) self.allocator.free(ev.name);
            if (ev.text.len > 0) self.allocator.free(ev.text);
        }
        self.stream_events.clearRetainingCapacity();
    }

    /// 每帧取出增量与事件并检测结束状态
    fn pumpStream(self: *AppState) void {
        // 1) 内容增量（先于事件处理，保证显示顺序）
        var content: ?[]u8 = null;
        var reasoning: ?[]u8 = null;
        var events: std.ArrayListUnmanaged(StreamEvent) = .{ .items = &.{}, .capacity = 0 };
        self.stream_mutex.lockUncancelable(self.io);
        if (self.stream_buf.items.len > self.stream_consume_pos) {
            const slice = self.stream_buf.items[self.stream_consume_pos..];
            if (self.allocator.dupe(u8, slice)) |copy| {
                content = copy;
                self.stream_consume_pos = self.stream_buf.items.len;
            } else |_| {}
        }
        if (self.stream_reasoning_buf.items.len > self.stream_reasoning_pos) {
            const slice = self.stream_reasoning_buf.items[self.stream_reasoning_pos..];
            if (self.allocator.dupe(u8, slice)) |copy| {
                reasoning = copy;
                self.stream_reasoning_pos = self.stream_reasoning_buf.items.len;
            } else |_| {}
        }
        if (self.stream_events.items.len > 0) {
            events = self.stream_events;
            self.stream_events = .{ .items = &.{}, .capacity = 0 };
        }
        self.stream_mutex.unlock(self.io);

        if (reasoning) |c| {
            self.appendStreamReasoning(c);
            self.allocator.free(c);
        }
        if (content) |c| {
            self.appendStreamChunk(c);
            self.allocator.free(c);
        }

        // 2) 事件：回合结束 / 工具调用
        if (events.items.len > 0) {
            for (events.items) |ev| {
                const block_kind = toolBlockKind(ev.name);
                switch (ev.kind) {
                    .turn_end => self.closeCurrentTurn(),
                    .user_sent => self.setToast("排队消息已送达"),
                    .tool_start => {
                        // bash/edit：先放一个只含标题的块（结果到达后追加正文）
                        const started = if (block_kind != null) self.beginToolBlock(ev.name, ev.args, block_kind.?) else false;
                        if (!started) {
                            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                            defer arena_state.deinit();
                            const line = formatToolCallLine(arena_state.allocator(), ev.name, ev.args);
                            self.addStreamMessage(line, tool_call_style);
                        }
                    },
                    .tool_end => {
                        var handled = false;
                        if (block_kind) |kind| {
                            const body = if (ev.is_error) ev.text else ev.payload;
                            if (self.appendToolBlockBody(kind, body, ev.is_error)) handled = true;
                        }
                        // 非块工具：成功回填统计到调用行末尾；失败出红色错误行
                        if (!handled) {
                            if (ev.is_error) {
                                self.addToolNoteLine("↳ 失败 · {s}", .{ev.text}, .{ .fg = .red });
                            } else {
                                self.appendLastNoteSuffix(ev.text);
                            }
                        }
                    },
                }
                if (ev.name.len > 0) self.allocator.free(ev.name);
                if (ev.text.len > 0) self.allocator.free(ev.text);
                if (ev.args.len > 0) self.allocator.free(ev.args);
                if (ev.payload.len > 0) self.allocator.free(ev.payload);
            }
            events.deinit(self.allocator);
        }

        // 3) 状态检查：收尾后把仍未送达的排队消息作为新回合发出
        switch (self.streamStatus()) {
            .done, .canceled => {
                self.finalizeStream(null);
                self.flushPendingSends();
            },
            .failed => {
                self.finalizeStream(self.stream_error);
                self.flushPendingSends();
            },
            else => {},
        }
    }

    fn appendStreamChunk(self: *AppState, chunk: []const u8) void {
        const idx = self.ensureStreamingMessage() orelse return;
        const msg = &self.messages.items[idx];

        const first_content = msg.content.len == 0;
        const width = self.message_wrap_width;
        const rows_before = if (width > 0) messageRowCount(msg.*, width) else 0;

        const joined = self.allocator.alloc(u8, msg.content.len + chunk.len) catch return;
        @memcpy(joined[0..msg.content.len], msg.content);
        @memcpy(joined[msg.content.len..], chunk);
        if (msg.content.len > 0) self.allocator.free(msg.content);
        msg.content = joined;

        // 重新解析 Markdown（整段，KB 级内容足够快）
        if (msg.md) |old| md_mod.free(self.allocator, old);
        msg.md = md_mod.parse(self.allocator, joined, md_mod.default_styles) catch null;

        // 贴底时保持跟随；已上翻时补偿偏移，保持视口不动
        if (width > 0) {
            const rows_after = messageRowCount(msg.*, width);
            const added = rows_after -| rows_before;
            if (self.scroll_offset > 0 and added > 0) self.scroll_offset +|= added;
        }

        // 思考结束（正文开始）：始终自动折叠（即使中途手动展开过）
        if (first_content and msg.reasoning != null) {
            setThoughtExpanded(self, idx, false, false);
        }
    }

    fn appendStreamReasoning(self: *AppState, chunk: []const u8) void {
        const idx = self.ensureStreamingMessage() orelse return;
        const msg = &self.messages.items[idx];

        const first_reasoning = msg.reasoning == null;
        const width = self.message_wrap_width;
        const rows_before = if (width > 0) messageRowCount(msg.*, width) else 0;

        const now = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (msg.reasoning == null) msg.reasoning_start_ms = now;
        msg.reasoning_end_ms = now;

        const old: []const u8 = if (msg.reasoning) |r| r else "";
        const joined = self.allocator.alloc(u8, old.len + chunk.len) catch return;
        @memcpy(joined[0..old.len], old);
        @memcpy(joined[old.len..], chunk);
        if (old.len > 0) self.allocator.free(old);
        msg.reasoning = joined;

        // 贴底时保持跟随；已上翻时补偿偏移，保持视口不动
        if (width > 0) {
            const rows_after = messageRowCount(msg.*, width);
            const added = rows_after -| rows_before;
            if (self.scroll_offset > 0 and added > 0) self.scroll_offset +|= added;
        }

        // 思考开始：展开，流式显示思考内容（思考结束后自动折叠）
        if (first_reasoning) {
            setThoughtExpanded(self, idx, true, false);
        }
    }

    /// 收尾：join 线程、转录入历史、落库、清理共享状态（err 非空时显示错误）
    fn finalizeStream(self: *AppState, err: ?ai.AIError) void {
        if (self.stream_thread) |t| {
            t.join();
            self.stream_thread = null;
        }

        // 收尾前折叠最后一个思考块（最终回答可能没有正文，或思考中被取消）
        self.collapseStreamingThought();

        // 定格当前回合的思考时长与文本
        var reasoning_text: []const u8 = "";
        var reasoning_ms: i64 = 0;
        if (self.streaming_msg_idx) |idx| {
            if (idx < self.messages.items.len) {
                const msg = &self.messages.items[idx];
                if (msg.reasoning != null and msg.reasoning_ms == 0) {
                    msg.reasoning_ms = if (msg.reasoning_end_ms > msg.reasoning_start_ms)
                        msg.reasoning_end_ms - msg.reasoning_start_ms
                    else
                        0;
                }
                reasoning_text = if (msg.reasoning) |r| r else "";
                reasoning_ms = msg.reasoning_ms;
            }
        }

        // 转录 → 内存历史 + 落库（含工具交互）；每轮的思考挂在对应 assistant 消息上
        var error_detail: []const u8 = "";
        if (self.stream_job) |job| {
            // 必须在 job.deinit() 前复制出来（slice 指向 job arena）
            if (job.error_detail.len > 0) {
                error_detail = self.allocator.dupe(u8, job.error_detail) catch "";
            }

            // 是否已有带正文的 assistant 回复（决定是否需要显示消息兜底落库）
            var has_final = false;
            for (job.transcript.items) |entry| {
                if (std.mem.eql(u8, entry.msg.role, "assistant") and entry.msg.content.len > 0) has_final = true;
            }
            var worker_persisted_max: i64 = 0;

            for (job.transcript.items) |entry| {
                const m = entry.msg;
                // 实时落库路径：worker 已写入，只补进主线程历史（避免重复写库）
                if (m.db_id != 0) {
                    if (m.db_id > worker_persisted_max) worker_persisted_max = m.db_id;
                    self.appendHistoryMessage(m);
                    continue;
                }
                // 工具调用 → JSON 文本落库
                var calls_json: []const u8 = "";
                var calls_buf: ?[]u8 = null;
                defer if (calls_buf) |b| self.allocator.free(b);
                if (m.tool_calls) |calls| {
                    if (toolCallsToJson(self.allocator, calls)) |json| {
                        calls_buf = json;
                        calls_json = json;
                    } else |_| {}
                }
                // 工具结果：取出渲染元数据（工具名 / diff 正文 / 错误标志）
                var t_name: []const u8 = "";
                var t_display: []const u8 = "";
                var t_error: i64 = 0;
                if (std.mem.eql(u8, m.role, "tool")) {
                    if (m.tool_call_id) |cid| {
                        for (job.tool_meta.items) |tm| {
                            if (std.mem.eql(u8, tm.id, cid)) {
                                t_name = tm.name;
                                t_display = tm.display;
                                t_error = if (tm.is_error) 1 else 0;
                                break;
                            }
                        }
                    }
                }
                const db_id = self.persistMessage(.{
                    .role = m.role,
                    .content = m.content,
                    .model = job.model,
                    .provider = job.provider_name,
                    .reasoning = entry.reasoning,
                    .reasoning_ms = entry.reasoning_ms,
                    .tool_calls = calls_json,
                    .tool_call_id = m.tool_call_id orelse "",
                    .tool_name = t_name,
                    .tool_display = t_display,
                    .tool_full = "",
                    .is_error = t_error,
                    .input_tokens = @intCast(entry.usage.input_tokens),
                    .cached_tokens = @intCast(entry.usage.cached_tokens),
                    .output_tokens = @intCast(entry.usage.output_tokens),
                });
                if (db_id > worker_persisted_max) worker_persisted_max = db_id;
                var hist = m;
                hist.db_id = db_id;
                self.appendHistoryMessage(hist);
            }
            // worker 落库的行不算"外部写入"：同步游标，避免外部轮询把它们当新消息重复加载
            if (worker_persisted_max > self.last_seen_msg_id) self.last_seen_msg_id = worker_persisted_max;

            // 取消/出错时当前回合可能未入转录：用显示消息兜底落库
            if (!has_final) {
                if (self.streaming_msg_idx) |idx| {
                    if (idx < self.messages.items.len) {
                        const content = self.messages.items[idx].content;
                        if (content.len > 0) {
                            _ = self.persistMessage(.{
                                .role = "assistant",
                                .content = content,
                                .model = job.model,
                                .provider = job.provider_name,
                                .reasoning = reasoning_text,
                                .reasoning_ms = reasoning_ms,
                            });
                        }
                    }
                }
            }
        }

        self.closeCurrentTurn();

        if (self.stream_job) |job| {
            const compacted_midturn = job.compacted_midturn;
            self.last_usage = .{
                .input_tokens = job.usage_input,
                .output_tokens = job.usage_output,
                .cached_tokens = job.usage_cached,
            };
            // 上下文占用只取最后一轮请求：多轮工具循环累计会虚高（如 35 轮 → 1.1M）
            self.context_usage = job.round_usage;
            self.usage_estimated = false; // 真实用量
            // usage 锚点：本轮最后一轮真实 usage + 其后增量，供下次估算使用。
            // 只认正常结束的回合：取消/失败时 history 可能含部分内容，用旧 usage 当锚点会低估
            const anchor_tokens: u64 = job.round_usage.input_tokens + job.round_usage.output_tokens;
            const anchor_ok = self.streamStatus() == .done and err == null and job.round_usage.input_tokens > 0;
            job.deinit();
            self.stream_job = null;
            // 工具循环中途压缩过：主线程历史按 checkpoint 重建（显示保持不变）
            if (compacted_midturn) {
                self.rebuildHistoryFromDb();
                self.usage_anchor_len = null; // 重建后的前缀与 round_usage 不对应
                self.usage_anchor_tokens = 0;
            } else if (anchor_ok) {
                self.usage_anchor_tokens = anchor_tokens;
                self.usage_anchor_len = self.history.items.len;
            } else {
                self.usage_anchor_len = null;
                self.usage_anchor_tokens = 0;
            }
        }
        defer if (error_detail.len > 0) self.allocator.free(error_detail);

        self.stream_mutex.lockUncancelable(self.io);
        self.stream_buf.clearRetainingCapacity();
        self.stream_consume_pos = 0;
        self.stream_reasoning_buf.clearRetainingCapacity();
        self.stream_reasoning_pos = 0;
        self.clearStreamEventsLocked();
        self.stream_mutex.unlock(self.io);
        self.stream_error = null;
        self.setStreamStatus(.idle);

        // 回合无恙：检查是否需要批量折叠较早的工具输出（只动发给模型的 history，
        // 全文写入 DB 的 tool_full，UI/重启后仍可见全文）
        if (err == null) {
            _ = self.maybeFoldOldToolOutputs();
        }

        if (err) |e| {
            var err_buf: [256]u8 = undefined;
            const err_msg: []const u8 = switch (e) {
                error.StreamTruncated => "连接中断：响应流未正常结束，本次回复可能不完整（可重发消息重试）",
                else => std.fmt.bufPrint(&err_buf, "AI 请求失败: {}", .{e}) catch "AI 请求失败",
            };
            self.addMessage(err_msg, .{ .fg = .red });
            if (error_detail.len > 0) {
                // 只取首行、截断到 ~200 字符
                const nl = std.mem.indexOfScalar(u8, error_detail, '\n') orelse error_detail.len;
                var line = error_detail[0..nl];
                if (line.len > 200) {
                    var cut: usize = 200;
                    while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1;
                    line = line[0..cut];
                }
                var detail_buf: [512]u8 = undefined;
                const detail_msg = std.fmt.bufPrint(&detail_buf, "服务端返回: {s}", .{line}) catch "服务端返回错误详情";
                self.addMessage(detail_msg, .{ .fg = .dark_gray });
            }
            // 截断属瞬时网络/网关问题，配置检查清单不适用
            if (e != error.StreamTruncated) {
                self.addMessage("请检查: 1) 提供商服务是否已启动（如 LM Studio）/ 网络是否可用  2) API Key 是否正确  3) URL 与模型名称是否正确", .{ .fg = .dark_gray });
            }
        }
    }

    /// 折叠较早的工具输出：只改发给模型的 history（content→stub），
    /// 全文写回 DB 的 tool_full 列，UI/重启后仍可看到全文。
    /// 返回折叠条数（0 = 未触发）。判定规则见 FoldScanner（回合保护/窗口/stub 边界），
    /// 与 /context 的模拟共用同一实现，避免展示与实际不一致。
    fn maybeFoldOldToolOutputs(self: *AppState) usize {
        const db = if (self.db) |*d| d else return 0;
        if (self.history.items.len == 0) return 0;

        // 调用 id → 工具名（stub 文案用）
        const CallName = struct { id: []const u8, name: []const u8 };
        var calls = std.ArrayListUnmanaged(CallName){ .items = &.{}, .capacity = 0 };
        defer calls.deinit(self.allocator);
        for (self.history.items) |m| {
            if (m.tool_calls) |cs| {
                for (cs) |c| calls.append(self.allocator, .{ .id = c.id, .name = c.name }) catch return 0;
            }
        }

        // 第一遍（从新到旧）：统计候选量与是否触发
        var scan = FoldScanner{};
        var i: usize = self.history.items.len;
        while (i > 0) {
            i -= 1;
            const m = self.history.items[i];
            if (scan.feed(m.role, m.content, m.db_id != 0) == .stop) break;
        }
        if (!scan.result().triggered) return 0;

        // 第二遍：批量折叠（判定顺序与第一遍完全一致）
        var scan2 = FoldScanner{};
        var folded: usize = 0;
        var saved: usize = 0;
        i = self.history.items.len;
        while (i > 0) {
            i -= 1;
            const m = &self.history.items[i];
            switch (scan2.feed(m.role, m.content, m.db_id != 0)) {
                .stop => break,
                .skip => {},
                .candidate => {
                    const tool_name = blk: {
                        for (calls.items) |c| {
                            if (std.mem.eql(u8, c.id, m.tool_call_id orelse "")) break :blk c.name;
                        }
                        break :blk "tool";
                    };
                    var stub_buf: [192]u8 = undefined;
                    const stub = std.fmt.bufPrint(&stub_buf, "{s}：{s} 输出 {d} 字符。如需内容请重新调用该工具]", .{
                        fold_marker,
                        tool_name,
                        m.content.len,
                    }) catch continue;
                    db.foldToolMessage(m.db_id, stub, m.content) catch continue;
                    const new_content = self.allocator.dupe(u8, stub) catch continue;
                    saved += m.content.len;
                    self.allocator.free(@constCast(m.content));
                    m.content = new_content;
                    folded += 1;
                },
            }
        }

        if (folded > 0) {
            // 折叠缩小了发往模型的真实前缀：锚点 token 数同步递减
            if (self.usage_anchor_len != null and saved > 0) {
                const cut: u64 = @intCast(estimateTokens(saved));
                self.usage_anchor_tokens -|= cut;
            }
            var note_buf: [96]u8 = undefined;
            const note = std.fmt.bufPrint(&note_buf, "已折叠 {d} 条旧工具输出（约 {d}KB）", .{
                folded,
                saved / 1024,
            }) catch "";
            if (note.len > 0) self.setToast(note);
        }
        return folded;
    }

    fn freeModelSelectModels(self: *AppState) void {
        if (self.model_select_models.len > 0) {
            for (self.model_select_models) |m| {
                self.allocator.free(m.id);
            }
            self.allocator.free(self.model_select_models);
        }
        self.model_select_models = &.{};
    }

    // 拉取指定提供商的模型列表，成功后进入 provider_models 模式
    fn fetchModelsForProvider(self: *AppState, provider_idx: usize) bool {
        if (provider_idx >= self.config.providers.items.len) return false;
        const p = self.config.providers.items[provider_idx];

        var client = ai.AI.init(self.allocator, self.io, .{
            .api_key = self.resolvedApiKey(&p),
            .endpoint = p.endpoint,
            .model = self.config.current_model,
            .session_id = self.sessionUuid(),
            .behavior = config_mod.behavior(&p),
        });
        client.environ_map = self.environ_map;

        self.freeModelSelectModels();

        const all_models = client.listModels() catch |err| {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "获取模型列表失败: {}", .{err}) catch "获取模型列表失败";
            self.addMessage(err_msg, .{ .fg = .red });
            if (err == error.InvalidApiKey) {
                self.addMessage("提示: API Key 可能不正确，按 Ctrl+E 编辑该提供商", .{ .fg = .yellow });
            } else {
                self.addMessage("该 API 可能不支持 /models 接口", .{ .fg = .dark_gray });
            }
            return false;
        };
        defer self.allocator.free(all_models);

        if (all_models.len == 0) {
            self.addMessage("未找到可用模型 (可能该 API 不支持 /models 接口)", .{ .fg = .yellow });
            return false;
        }

        const models_copy = self.allocator.alloc(ai.ModelInfo, all_models.len) catch {
            for (all_models) |m| {
                self.allocator.free(m.id);
            }
            return false;
        };
        @memcpy(models_copy, all_models);
        self.model_select_models = models_copy;
        self.model_select_provider = provider_idx;
        self.model_select_index = 0;
        self.model_view_start = 0;
        return true;
    }

    // 切换到指定提供商的模型
    fn selectModel(self: *AppState, provider_idx: usize, model_id: []const u8) void {
        if (provider_idx >= self.config.providers.items.len) return;
        if (model_id.len == 0) return;

        self.config.setCurrentModel(self.allocator, model_id);
        self.config.setCurrentProvider(self.allocator, self.config.providers.items[provider_idx].name);
        self.config.save(self.io, self.allocator);
        self.addRecentModel(provider_idx, model_id);
    }

    fn addRecentModel(self: *AppState, provider_idx: usize, model_id: []const u8) void {
        // 检查是否已存在
        for (0..self.model_select_recent_count) |i| {
            const e = self.model_select_recent[i];
            if (e.provider == provider_idx and std.mem.eql(u8, e.name[0..e.len], model_id)) {
                // 已存在，移到最前面
                if (i > 0) {
                    const temp = self.model_select_recent[i];
                    var j: usize = i;
                    while (j > 0) : (j -= 1) {
                        self.model_select_recent[j] = self.model_select_recent[j - 1];
                    }
                    self.model_select_recent[0] = temp;
                }
                return;
            }
        }
        // 添加新的，如果满了就移除最后一个
        if (self.model_select_recent_count >= 5) {
            var j: usize = 4;
            while (j > 0) : (j -= 1) {
                self.model_select_recent[j] = self.model_select_recent[j - 1];
            }
            self.model_select_recent_count = 4;
        }
        // 插入到最前面
        var j: usize = self.model_select_recent_count;
        while (j > 0) : (j -= 1) {
            self.model_select_recent[j] = self.model_select_recent[j - 1];
        }
        const copy_len = @min(model_id.len, 127);
        @memcpy(self.model_select_recent[0].name[0..copy_len], model_id[0..copy_len]);
        self.model_select_recent[0].len = copy_len;
        self.model_select_recent[0].provider = provider_idx;
        if (self.model_select_recent_count < 5) self.model_select_recent_count += 1;
    }

    fn providerFormActiveInput(self: *AppState) *TextInput(256) {
        return switch (self.provider_form_field) {
            0 => &self.provider_form_name,
            1 => &self.provider_form_url,
            2 => &self.provider_form_key,
            else => &self.provider_form_key_env,
        };
    }

    fn providerFormUpdateFocus(self: *AppState) void {
        self.provider_form_name.focused = self.provider_form_field == 0;
        self.provider_form_url.focused = self.provider_form_field == 1;
        self.provider_form_key.focused = self.provider_form_field == 2;
        self.provider_form_key_env.focused = self.provider_form_field == 3;
    }

    /// 预设表单：名称/地址来自预设，只读不可修改（仅新增时；编辑已有条目仍可改）
    fn providerFormLocked(self: *const AppState) bool {
        return self.provider_edit_index == null and self.providerFormPreset().len > 0;
    }

    fn providerFormNext(self: *AppState) void {
        var next = (self.provider_form_field + 1) % 4;
        // 只读表单跳过名称/地址两栏
        if (self.providerFormLocked() and next < 2) next = 2;
        self.provider_form_field = next;
        self.providerFormUpdateFocus();
    }

    fn providerFormPrev(self: *AppState) void {
        var prev = if (self.provider_form_field == 0) 3 else self.provider_form_field - 1;
        if (self.providerFormLocked() and prev < 2) prev = 3;
        self.provider_form_field = prev;
        self.providerFormUpdateFocus();
    }

    fn resetProviderForm(self: *AppState) void {
        self.provider_form_name.clear();
        self.provider_form_url.clear();
        self.provider_form_key.clear();
        self.provider_form_key_env.clear();
        self.provider_form_field = 0;
        self.provider_edit_index = null;
        self.provider_form_preset_len = 0;
        self.providerFormUpdateFocus();
    }

    fn providerFormPreset(self: *const AppState) []const u8 {
        return self.provider_form_preset[0..self.provider_form_preset_len];
    }

    fn setProviderFormPreset(self: *AppState, id: []const u8) void {
        const len = @min(id.len, self.provider_form_preset.len);
        @memcpy(self.provider_form_preset[0..len], id[0..len]);
        self.provider_form_preset_len = len;
    }

    fn setFormText(input: *TextInput(256), text: []const u8) void {
        input.clear();
        input.insertBytes(text);
    }

    /// 打开预设选择器（Ctrl+A / 列表项入口）
    fn startProviderAdd(self: *AppState) void {
        self.preset_select_index = 0;
        self.mode = .preset_select;
    }

    /// 选定预设后进入表单（preset 为 null 表示自定义）
    fn beginProviderFormWithPreset(self: *AppState, preset: ?*const config_mod.Preset) void {
        self.resetProviderForm();
        if (preset) |pr| {
            self.setProviderFormPreset(pr.id);
            setFormText(&self.provider_form_name, pr.id);
            setFormText(&self.provider_form_url, pr.endpoint);
            setFormText(&self.provider_form_key_env, pr.api_key_env);
            // 名称/地址只读：光标直接落在密钥栏
            self.provider_form_field = 2;
        }
        self.providerFormUpdateFocus();
        self.mode = .provider_add;
    }

    fn startProviderEdit(self: *AppState, provider_idx: usize) void {
        if (provider_idx >= self.config.providers.items.len) return;
        const p = self.config.providers.items[provider_idx];
        self.resetProviderForm();
        setFormText(&self.provider_form_name, p.name);
        setFormText(&self.provider_form_url, p.endpoint);
        setFormText(&self.provider_form_key, p.api_key);
        setFormText(&self.provider_form_key_env, p.api_key_env);
        self.setProviderFormPreset(p.preset);
        self.provider_edit_index = provider_idx;
        self.provider_form_field = 0;
        self.providerFormUpdateFocus();
        self.mode = .provider_add;
    }

    fn providerSpecFromForm(self: *const AppState, name: []const u8, url: []const u8, key: []const u8) config_mod.ProviderSpec {
        return .{
            .name = name,
            .endpoint = url,
            .api_key = key,
            .preset = self.providerFormPreset(),
            .api_key_env = self.provider_form_key_env.value(),
        };
    }

    fn saveProviderForm(self: *AppState) void {
        const name = self.provider_form_name.value();
        const url = self.provider_form_url.value();
        const key = self.provider_form_key.value();

        if (name.len == 0) {
            self.addMessage("提供商名称不能为空", .{ .fg = .red });
            self.provider_form_field = 0;
            self.providerFormUpdateFocus();
            return;
        }
        if (name.len > 64) {
            self.addMessage("提供商名称过长 (最多 64 字符)", .{ .fg = .red });
            return;
        }
        if (url.len == 0) {
            self.addMessage("API 地址不能为空", .{ .fg = .red });
            self.provider_form_field = 1;
            self.providerFormUpdateFocus();
            return;
        }

        // 编辑已有提供商
        if (self.provider_edit_index) |idx| {
            if (idx < self.config.providers.items.len) {
                if (self.providerNameExists(name, idx)) {
                    self.addMessage("已存在同名提供商", .{ .fg = .red });
                    self.provider_form_field = 0;
                    self.providerFormUpdateFocus();
                    return;
                }
                const was_current = self.isCurrentProvider(idx);
                if (!self.config.updateProvider(self.allocator, idx, self.providerSpecFromForm(name, url, key))) {
                    self.addMessage("内存分配失败", .{ .fg = .red });
                    return;
                }

                // 若重命名的是当前提供商，同步更新 current 引用
                if (was_current) {
                    self.config.setCurrentProvider(self.allocator, name);
                }

                self.config.save(self.io, self.allocator);

                // 光标定位到该提供商条目
                self.model_select_index = self.model_select_recent_count + idx;
                self.resetProviderForm();
                self.mode = .model_select;
                return;
            }
        }

        // 新增提供商
        if (self.providerNameExists(name, null)) {
            self.addMessage("已存在同名提供商", .{ .fg = .red });
            self.provider_form_field = 0;
            self.providerFormUpdateFocus();
            return;
        }
        if (!self.config.appendProvider(self.allocator, self.providerSpecFromForm(name, url, key))) {
            self.addMessage("添加提供商失败 (内存不足)", .{ .fg = .red });
            return;
        }

        // 若当前未选中任何提供商，则默认选中新添加的
        if (self.config.current_provider_name.len == 0) {
            self.config.setCurrentProvider(self.allocator, name);
        }

        self.config.save(self.io, self.allocator);

        // 光标定位到新添加的提供商条目
        self.model_select_index = self.model_select_recent_count + self.config.providers.items.len - 1;

        self.resetProviderForm();
        self.mode = .model_select;
    }

    /// 删除提供商（含当前项与最近模型引用的修正）
    fn deleteProviderAt(self: *AppState, idx: usize) void {
        if (idx >= self.config.providers.items.len) return;
        const was_current = self.isCurrentProvider(idx);
        const name_copy = self.allocator.dupe(u8, self.config.providers.items[idx].name) catch null;
        defer if (name_copy) |n| self.allocator.free(n);

        self.config.removeProvider(self.allocator, idx);

        // 最近使用列表：删除指向该项的条目，并修正后续下标
        pruneRecentProviderRefs(&self.model_select_recent, &self.model_select_recent_count, idx);

        if (was_current) {
            if (self.config.providers.items.len > 0) {
                self.config.setCurrentProvider(self.allocator, self.config.providers.items[0].name);
            } else {
                self.config.setCurrentProvider(self.allocator, "");
            }
        }

        // 光标位置修正（末项是"+ 添加提供商"）
        const total = self.model_select_recent_count + self.config.providers.items.len + 1;
        if (self.model_select_index >= total) self.model_select_index = total - 1;
        self.config.save(self.io, self.allocator);

        var sb: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&sb, "已删除提供商 {s}", .{name_copy orelse "?"}) catch "已删除提供商";
        self.addMessage(text, .{ .fg = .dark_gray });
    }

    fn isCtrlA(key: tui.KeyEvent) bool {
        if (!key.modifiers.ctrl) return false;
        return switch (key.code) {
            .char => |c| c == 1 or c == 'a' or c == 'A',
            else => false,
        };
    }

    fn isCtrlE(key: tui.KeyEvent) bool {
        if (!key.modifiers.ctrl) return false;
        return switch (key.code) {
            .char => |c| c == 5 or c == 'e' or c == 'E',
            else => false,
        };
    }

    fn handleModelSelectKey(self: *AppState, key: tui.KeyEvent) void {
        if (isCtrlA(key)) {
            self.startProviderAdd();
            return;
        }
        if (isCtrlE(key)) {
            // 编辑当前光标选中项所属的提供商
            if (self.model_select_index < self.model_select_recent_count) {
                const entry = self.model_select_recent[self.model_select_index];
                self.startProviderEdit(entry.provider);
            } else {
                const prov_idx = self.model_select_index - self.model_select_recent_count;
                self.startProviderEdit(prov_idx);
            }
            return;
        }

        const provider_count = self.config.providers.items.len;
        // 末项固定为「+ 添加提供商…」
        const total_items = self.model_select_recent_count + provider_count + 1;
        if (self.model_select_index >= total_items) {
            self.model_select_index = total_items - 1;
        }

        switch (key.code) {
            .up => {
                self.model_select_index = if (self.model_select_index == 0) total_items - 1 else self.model_select_index - 1;
            },
            .down => {
                self.model_select_index = if (self.model_select_index + 1 >= total_items) 0 else self.model_select_index + 1;
            },
            .delete => {
                // Del：删除光标所在的提供商（弹出确认对话框）
                if (self.model_select_index < self.model_select_recent_count) return;
                const prov_idx = self.model_select_index - self.model_select_recent_count;
                if (prov_idx >= provider_count) return;
                self.provider_confirm_index = prov_idx;
                self.confirm_stage = 1;
                self.confirm_yes = false; // 默认停在"否"
                self.mode = .provider_confirm;
            },
            .enter => {
                if (self.model_select_index < self.model_select_recent_count) {
                    const entry = self.model_select_recent[self.model_select_index];
                    self.selectModel(entry.provider, entry.name[0..entry.len]);
                    self.mode = .normal;
                } else if (self.model_select_index - self.model_select_recent_count >= provider_count) {
                    // 「+ 添加提供商…」
                    self.startProviderAdd();
                } else {
                    const prov_idx = self.model_select_index - self.model_select_recent_count;
                    if (self.fetchModelsForProvider(prov_idx)) {
                        self.mode = .provider_models;
                    }
                }
            },
            .esc => {
                self.closeMenu();
            },
            else => {},
        }
    }

    /// 预设选择器：Enter 选定并进入表单，末项为自定义
    fn handlePresetSelectKey(self: *AppState, key: tui.KeyEvent) void {
        const total = config_mod.presets.len + 1;
        if (self.preset_select_index >= total) self.preset_select_index = total - 1;

        switch (key.code) {
            .up => {
                self.preset_select_index = if (self.preset_select_index == 0) total - 1 else self.preset_select_index - 1;
            },
            .down => {
                self.preset_select_index = if (self.preset_select_index + 1 >= total) 0 else self.preset_select_index + 1;
            },
            .enter => {
                if (self.preset_select_index < config_mod.presets.len) {
                    self.beginProviderFormWithPreset(&config_mod.presets[self.preset_select_index]);
                } else {
                    self.beginProviderFormWithPreset(null);
                }
            },
            .esc => self.mode = .model_select,
            else => {},
        }
    }

    fn handleProviderConfirmKey(self: *AppState, key: tui.KeyEvent) void {
        switch (key.code) {
            .left, .right, .tab, .back_tab => {
                self.confirm_yes = !self.confirm_yes;
            },
            .enter => {
                if (!self.confirm_yes) {
                    // 选择"否" → 取消
                    self.provider_confirm_index = null;
                    self.confirm_stage = 0;
                    self.mode = .model_select;
                    return;
                }
                if (self.confirm_stage == 1) {
                    // 第一关通过，进入第二关（光标重新回到"否"）
                    self.confirm_stage = 2;
                    self.confirm_yes = false;
                } else {
                    self.deleteConfirmedProvider();
                }
            },
            .esc, .delete => {
                self.provider_confirm_index = null;
                self.confirm_stage = 0;
                self.mode = .model_select;
            },
            else => {},
        }
    }

    fn deleteConfirmedProvider(self: *AppState) void {
        const idx = self.provider_confirm_index orelse {
            self.confirm_stage = 0;
            self.mode = .model_select;
            return;
        };
        self.provider_confirm_index = null;
        self.deleteProviderAt(idx);
        self.confirm_stage = 0;
        self.mode = .model_select;
    }

    /// 压缩确认框（从 Esc 菜单进入；两关确认，参考删除会话/提供商的交互）
    fn handleCompactConfirmKey(self: *AppState, key: tui.KeyEvent) void {
        switch (key.code) {
            .left, .right, .tab, .back_tab => {
                self.confirm_yes = !self.confirm_yes;
            },
            .enter => {
                if (!self.confirm_yes) {
                    // 选择"否" → 取消
                    self.confirm_stage = 0;
                    self.mode = .normal;
                    return;
                }
                if (self.confirm_stage == 1) {
                    // 第一关通过，进入第二关（光标重新回到"否"）
                    self.confirm_stage = 2;
                    self.confirm_yes = false;
                } else {
                    self.confirm_stage = 0;
                    self.mode = .normal;
                    self.runCompactCommand(0);
                }
            },
            .esc, .delete => {
                self.confirm_stage = 0;
                self.mode = .normal;
            },
            else => {},
        }
    }

    fn handleProviderModelsKey(self: *AppState, key: tui.KeyEvent) void {
        if (isCtrlE(key)) {
            self.startProviderEdit(self.model_select_provider);
            return;
        }
        if (isCtrlA(key)) {
            self.startProviderAdd();
            return;
        }

        const total = self.model_select_models.len;
        const visible = if (self.menu_visible_rows > 0) self.menu_visible_rows else 10;
        switch (key.code) {
            .up => {
                if (total > 0) {
                    self.model_select_index = if (self.model_select_index == 0) total - 1 else self.model_select_index - 1;
                    self.clampModelViewStart(visible);
                }
            },
            .down => {
                if (total > 0) {
                    self.model_select_index = if (self.model_select_index + 1 >= total) 0 else self.model_select_index + 1;
                    self.clampModelViewStart(visible);
                }
            },
            .enter => {
                if (self.model_select_index < total) {
                    const m = self.model_select_models[self.model_select_index];
                    self.selectModel(self.model_select_provider, m.id);
                    self.mode = .normal;
                }
            },
            .esc => {
                self.mode = .model_select;
                // 光标回到刚才查看的提供商条目
                const provider_count = self.config.providers.items.len;
                if (self.model_select_provider < provider_count) {
                    self.model_select_index = self.model_select_recent_count + self.model_select_provider;
                }
            },
            else => {},
        }
    }

    fn handleProviderAddKey(self: *AppState, key: tui.KeyEvent) void {
        // Ctrl+U 清空当前字段
        if (key.modifiers.ctrl) {
            switch (key.code) {
                .char => |c| {
                    if (c == 21 or c == 'u' or c == 'U') {
                        self.providerFormActiveInput().clear();
                        return;
                    }
                },
                else => {},
            }
        }
        switch (key.code) {
            .tab, .down => self.providerFormNext(),
            .back_tab, .up => self.providerFormPrev(),
            .enter => {
                if (self.provider_form_field < 3) {
                    self.providerFormNext();
                } else {
                    self.saveProviderForm();
                }
            },
            .esc => {
                self.resetProviderForm();
                self.mode = .model_select;
            },
            .char => |c| {
                if (c >= 0x20) self.providerFormActiveInput().insertCodepoint(c);
            },
            .backspace => self.providerFormActiveInput().deleteBackward(),
            .delete => self.providerFormActiveInput().deleteForward(),
            .left => self.providerFormActiveInput().moveCursorLeft(),
            .right => self.providerFormActiveInput().moveCursorRight(),
            .home => self.providerFormActiveInput().moveCursorHome(),
            .end => self.providerFormActiveInput().moveCursorEnd(),
            else => {},
        }
    }

    fn handleNormalKey(self: *AppState, key: tui.KeyEvent) void {
        // 任意按键打断拖动（保留选区）
        if (self.sel_dragging) self.stopDragging();

        // 记录事件间隔，用于识别粘贴产生的换行
        const now_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        const delta_ms = now_ms - self.last_key_ms;
        self.last_key_ms = now_ms;

        switch (key.code) {
            .char => |c| {
                // Ctrl 组合键：仅处理复制/剪切/全选，其余不插入字符
                if (key.modifiers.ctrl) {
                    switch (c) {
                        'c', 'C' => {
                            if (self.sel_active) self.copySelection();
                        },
                        // Ctrl+X (0x18)：剪切输入框选中内容
                        'x', 'X', 24 => {
                            if (self.sel_active) self.cutSelection();
                        },
                        'a', 'A' => self.selectAllInput(),
                        // Ctrl+Q：中断生成
                        17, 'q', 'Q' => self.cancelStream(),
                        else => {},
                    }
                    return;
                }
                // 有输入框选区时：输入即替换选中内容
                if (self.sel_active) {
                    if (self.sel_area == .input) {
                        self.deleteInputSelection();
                    } else {
                        self.clearSelection();
                    }
                }
                // Ctrl+J (LF) 视为换行；其余控制字符忽略
                if (c == '\n') {
                    self.input.insertCodepoint('\n');
                } else if (c >= 0x20) {
                    self.input.insertCodepoint(c);
                }
            },
            .enter => {
                if (self.sel_active) self.clearSelection();
                // Ctrl+Enter（或 Shift+Enter）插入换行
                if (key.modifiers.ctrl or key.modifiers.shift) {
                    self.input.insertCodepoint('\n');
                    return;
                }
                // 粘贴产生的换行：保持排版留在输入框
                if (isPasteNewline(delta_ms)) {
                    self.input.insertCodepoint('\n');
                    return;
                }
                const command = self.input.value();
                if (command.len > 0) {
                    // 指令：生成中保持忽略（压缩中照常执行，由各指令校验自身状态）
                    if (isCommandInput(command)) {
                        if (!self.isStreaming()) {
                            self.handleInput(command);
                            self.input.clear();
                        }
                        return;
                    }
                    // 生成/压缩中：排队，稍后在工具轮次边界注入或本轮结束后发出
                    if (self.isStreaming() or self.isCompacting()) {
                        self.queuePendingSend(command);
                        self.input.clear();
                        return;
                    }
                    // 常规发送：消息回显到聊天区（竖条代替旧前缀）
                    self.addUserMessage(command);
                    self.handleInput(command);
                    self.input.clear();
                }
            },
            .backspace => {
                if (self.sel_active and self.sel_area == .input) {
                    self.deleteInputSelection();
                } else {
                    if (self.sel_active) self.clearSelection();
                    self.input.deleteBackward();
                }
            },
            .delete => {
                if (self.sel_active and self.sel_area == .input) {
                    self.deleteInputSelection();
                } else {
                    if (self.sel_active) self.clearSelection();
                    self.input.deleteForward();
                }
            },
            .left => self.input.moveCursorLeft(),
            .right => self.input.moveCursorRight(),
            .home => self.input.moveCursorLineHome(),
            .end => self.input.moveCursorLineEnd(),
            .up => {
                // 仅移动输入光标（聊天滚动用 PageUp/PageDown）
                _ = self.input.moveCursorVert(self.input_wrap_width, true);
            },
            .down => {
                _ = self.input.moveCursorVert(self.input_wrap_width, false);
            },
            .page_up => {
                self.scroll_offset +|= @max(self.messagePageRows() / 2, 1);
            },
            .page_down => {
                self.scroll_offset -|= @max(self.messagePageRows() / 2, 1);
            },
            .esc => {
                // 有选中内容时先清除选区；否则打开主菜单
                if (self.sel_active) {
                    self.clearSelection();
                } else {
                    self.menu_parent = null;
                    self.help_select_index = 0;
                    self.mode = .help_select;
                }
            },
            else => {},
        }
    }
};

// ── 无界面 CLI（脚本/自动化测试驱动同一套 agent 逻辑）──

// ── CLI 参数解析与输出辅助在 cli_args.zig（别名保持调用点不变）──
const cli_usage = cli.cli_usage;
const CliOptions = cli.CliOptions;
const isCliCommand = cli.isCliCommand;
const cliWriteStdout = cli.cliWriteStdout;
const cliWriteStderr = cli.cliWriteStderr;
const parseCliArgs = cli.parseCliArgs;
const cliJsonWrite = cli.cliJsonWrite;
fn cliOpenDb(allocator: Allocator, io: Io, opt: CliOptions) ?db_mod.Db {
    const path = allocator.dupeZ(u8, opt.db_path) catch return null;
    defer allocator.free(path);
    return db_mod.Db.openFile(allocator, io, path) catch null;
}

/// 会话解析结果：新建 / 已存在 / 不存在 / 参数非法
const SessionResolution = union(enum) {
    existing: i64,
    created: i64,
    not_found,
    invalid,
};

/// 解析会话参数：-new 强制新建；数字需存在；latest/空 取最近（create_if_missing 时没有则新建）
fn cliResolveSessionEx(db: *db_mod.Db, opt: CliOptions, create_if_missing: bool) SessionResolution {
    if (opt.new_session) {
        const id = db.createSession(opt.title) catch return .invalid;
        return .{ .created = id };
    }
    if (opt.session.len == 0 or std.mem.eql(u8, opt.session, "latest")) {
        if (db.latestSession() catch null) |s| return .{ .existing = s.id };
        if (!create_if_missing) return .not_found;
        const id = db.createSession(opt.title) catch return .invalid;
        return .{ .created = id };
    }
    const id = std.fmt.parseInt(i64, opt.session, 10) catch return .invalid;
    const exists = db.sessionExists(id) catch return .invalid;
    if (!exists) return .not_found;
    return .{ .existing = id };
}

/// 新建会话时写入 system 消息（与 TUI 行为一致）
fn cliInitSessionRow(db: *db_mod.Db, session_id: i64) void {
    _ = db.insertMessage(.{ .session_id = session_id, .role = "system", .content = system_prompt }) catch {};
}

fn cliPrintHelp(io: Io, to_stderr: bool) void {
    if (to_stderr) cliWriteStderr(io, cli_usage) else cliWriteStdout(io, cli_usage);
}

fn cmdSessions(allocator: Allocator, io: Io, opt: CliOptions) u8 {
    var db = cliOpenDb(allocator, io, opt) orelse {
        cliWriteStderr(io, "无法打开数据库\n");
        return 4;
    };
    defer db.deinit();

    const rows = db.listSessions() catch {
        cliWriteStderr(io, "读取会话列表失败\n");
        return 4;
    };

    if (opt.json) {
        const JRow = struct {
            id: i64,
            title: []const u8,
            messages: i64,
            last_active_at: i64,
        };
        var list = std.ArrayListUnmanaged(JRow){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        for (rows) |r| list.append(allocator, .{
            .id = r.id,
            .title = r.title,
            .messages = r.msg_count,
            .last_active_at = r.last_active_at,
        }) catch {};
        const json = cliJsonWrite(allocator, list.items) catch {
            cliWriteStderr(io, "JSON 序列化失败\n");
            return 4;
        };
        defer allocator.free(json);
        cliWriteStdout(io, json);
        cliWriteStdout(io, "\n");
        return 0;
    }

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    var buf: [640]u8 = undefined;
    for (rows) |r| {
        var tb: [64]u8 = undefined;
        const rel = formatRelativeTime(&tb, now, r.last_active_at);
        const title = if (r.title.len > 0) r.title else "(未命名)";
        const line = std.fmt.bufPrint(&buf, "{d}\t{s}\t{d} 条\t{s}\n", .{ r.id, title, r.msg_count, rel }) catch continue;
        cliWriteStdout(io, line);
    }
    return 0;
}

fn cmdMessages(allocator: Allocator, io: Io, opt: CliOptions) u8 {
    var db = cliOpenDb(allocator, io, opt) orelse {
        cliWriteStderr(io, "无法打开数据库\n");
        return 4;
    };
    defer db.deinit();

    const sid = switch (cliResolveSessionEx(&db, opt, false)) {
        .existing, .created => |id| id,
        .not_found => {
            cliWriteStderr(io, "没有可用会话（可用 -session <id|latest> 指定）\n");
            return 4;
        },
        .invalid => {
            cliWriteStderr(io, "会话参数无效\n");
            return 2;
        },
    };
    const all = db.loadMessages(sid) catch {
        cliWriteStderr(io, "读取消息失败\n");
        return 4;
    };
    const rows = if (opt.limit > 0 and all.len > opt.limit) all[all.len - opt.limit ..] else all;

    if (opt.json) {
        const JRow = struct {
            id: i64,
            role: []const u8,
            content: []const u8,
            reasoning: []const u8,
            tool_name: []const u8,
            tool_call_id: []const u8,
            tool_calls: []const u8,
            is_error: i64,
        };
        var list = std.ArrayListUnmanaged(JRow){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        for (rows) |r| list.append(allocator, .{
            .id = r.id,
            .role = r.role,
            .content = r.content,
            .reasoning = r.reasoning,
            .tool_name = r.tool_name,
            .tool_call_id = r.tool_call_id,
            .tool_calls = r.tool_calls,
            .is_error = r.is_error,
        }) catch {};
        const json = cliJsonWrite(allocator, list.items) catch {
            cliWriteStderr(io, "JSON 序列化失败\n");
            return 4;
        };
        defer allocator.free(json);
        cliWriteStdout(io, json);
        cliWriteStdout(io, "\n");
        return 0;
    }

    var buf: [2048]u8 = undefined;
    for (rows) |r| {
        var content = r.content;
        if (std.mem.indexOfScalar(u8, content, '\n')) |nl| content = content[0..nl];
        if (content.len > 300) {
            var cut: usize = 300;
            while (cut > 0 and (content[cut] & 0xC0) == 0x80) cut -= 1;
            content = content[0..cut];
        }
        const who = if (r.tool_name.len > 0) r.tool_name else r.role;
        const line = std.fmt.bufPrint(&buf, "#{d} [{s}] {s}\n", .{ r.id, who, content }) catch continue;
        cliWriteStdout(io, line);
    }
    return 0;
}

fn cmdNew(allocator: Allocator, io: Io, opt: CliOptions) u8 {
    var db = cliOpenDb(allocator, io, opt) orelse {
        cliWriteStderr(io, "无法打开数据库\n");
        return 4;
    };
    defer db.deinit();

    const sid = db.createSession(opt.title) catch {
        cliWriteStderr(io, "新建会话失败\n");
        return 4;
    };
    cliInitSessionRow(&db, sid);

    if (opt.json) {
        const J = struct { session_id: i64, title: []const u8 };
        const json = cliJsonWrite(allocator, J{ .session_id = sid, .title = opt.title }) catch return 4;
        defer allocator.free(json);
        cliWriteStdout(io, json);
        cliWriteStdout(io, "\n");
    } else {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}\n", .{sid}) catch return 4;
        cliWriteStdout(io, line);
    }
    return 0;
}

/// 过程输出：工具活动行 +（--stream 时）正文增量，全部走 stderr
const CliProgress = struct {
    quiet: bool = false,
    stream: bool = false,
    show_tools: bool = true,
    printed_msgs: usize = 0,
    streamed_len: usize = 0,

    fn isToolActivity(m: Message) bool {
        if (m.tool_block != null) return true;
        return std.mem.startsWith(u8, m.content, "→ ") or
            std.mem.startsWith(u8, m.content, "↳ ") or
            std.mem.startsWith(u8, m.content, "⚙");
    }

    fn tick(self: *CliProgress, state: *AppState) void {
        if (self.quiet) return;
        const io = state.io;

        if (self.stream) {
            if (state.streaming_msg_idx) |idx| {
                if (idx < state.messages.items.len) {
                    const m = state.messages.items[idx];
                    if (m.content.len > self.streamed_len) {
                        cliWriteStderr(io, m.content[self.streamed_len..]);
                        self.streamed_len = m.content.len;
                    }
                }
            }
        }

        if (!self.show_tools) {
            // 只推进游标，不打印
            while (self.printed_msgs < state.messages.items.len) {
                if (state.streaming_msg_idx == self.printed_msgs) break;
                self.printed_msgs += 1;
            }
            return;
        }

        while (self.printed_msgs < state.messages.items.len) : (self.printed_msgs += 1) {
            const i = self.printed_msgs;
            const m = state.messages.items[i];
            // 正在流式的 assistant 消息由 --stream 通道负责（或最终答案单独输出）
            if (state.streaming_msg_idx == i) break;
            if (!isToolActivity(m)) continue;
            var first = m.content;
            if (std.mem.indexOfScalar(u8, first, '\n')) |nl| first = first[0..nl];
            if (first.len > 300) {
                var cut: usize = 300;
                while (cut > 0 and (first[cut] & 0xC0) == 0x80) cut -= 1;
                first = first[0..cut];
            }
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}\n", .{first}) catch continue;
            cliWriteStderr(io, line);
        }
    }
};

/// 压缩提示文案（TUI 的 summary 气泡标题与压缩命令结果共用）
fn formatCompactionNotice(buf: []u8, compacted_count: usize, summary_len: usize, tokens_before: usize) []const u8 {
    var nb: [24]u8 = undefined;
    if (compacted_count > 0) {
        return std.fmt.bufPrint(buf, "▣ 上下文已压缩（以上 {d} 条消息不再发送） · 摘要 {d} 字节 · 压缩前约 {s} tok", .{
            compacted_count,
            summary_len,
            formatCount(&nb, @intCast(tokens_before)),
        }) catch "▣ 上下文已压缩";
    }
    return std.fmt.bufPrint(buf, "▣ 上下文已压缩 · 摘要 {d} 字节 · 压缩前约 {s} tok", .{
        summary_len,
        formatCount(&nb, @intCast(tokens_before)),
    }) catch "▣ 上下文已压缩";
}

/// 压缩结果（errDetail 供 CLI/TUI 展示服务端错误详情）
const CompactionOutcome = struct {
    compacted: bool = false,
    summarized_messages: usize = 0,
    summary_len: usize = 0,
    tokens_before: usize = 0,
    tail_start_id: i64 = 0,
    err: ?[]const u8 = null,
    err_detail_len: usize = 0,
    err_detail_buf: [256]u8 = undefined,

    fn errDetail(self: *const CompactionOutcome) []const u8 {
        return self.err_detail_buf[0..self.err_detail_len];
    }
};

const SummaryCollector = struct {
    allocator: Allocator,
    list: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },

    fn deinit(self: *SummaryCollector) void {
        self.list.deinit(self.allocator);
    }

    fn cb(ctx: *anyopaque, kind: ai.DeltaKind, delta: []const u8) void {
        if (kind != .content) return;
        const self: *SummaryCollector = @ptrCast(@alignCast(ctx));
        self.list.appendSlice(self.allocator, delta) catch {};
    }
};

/// 一次压缩任务（同步/异步共用）：持有历史快照与结果
const CompactionPlan = struct {
    app: *AppState,
    arena: *std.heap.ArenaAllocator,
    io: Io,
    /// true = 在 worker 线程执行（需要自建 DB 连接并流式回传）
    async: bool,
    db_path: [:0]const u8 = "",
    session_id: i64 = 0,
    endpoint: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    provider_name: []const u8 = "",
    behavior: config_mod.Behavior = .{},
    environ_map: ?*const std.process.Environ.Map = null,
    history: []ai.Message = &.{},
    keep_tokens: usize = 0,

    // 结果
    compacted: bool = false,
    summarized: usize = 0,
    summary_len: usize = 0,
    tokens_before: usize = 0,
    tail_start_id: i64 = 0,
    err: ?[]const u8 = null,
    err_detail_len: usize = 0,
    err_detail_buf: [256]u8 = undefined,

    fn deinit(self: *CompactionPlan) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        allocator.destroy(self);
    }
};

const SummaryDeltaCtx = struct { plan: *CompactionPlan, collector: *SummaryCollector };

/// 摘要流式回调：收集全文；异步模式下同时回传主线程渲染
fn onSummaryDelta(ctx: *anyopaque, kind: ai.DeltaKind, delta: []const u8) void {
    if (kind != .content) return;
    const w: *SummaryDeltaCtx = @ptrCast(@alignCast(ctx));
    w.collector.list.appendSlice(w.collector.allocator, delta) catch {};
    if (!w.plan.async) return;
    const app = w.plan.app;
    app.compact_mutex.lockUncancelable(app.io);
    defer app.compact_mutex.unlock(app.io);
    app.compact_buf.appendSlice(app.allocator, delta) catch {};
}

/// 执行压缩计划：选区间 → 摘要请求 → 摘要消息入库 + checkpoint 落库
fn compactionExecute(plan: *CompactionPlan) void {
    const app = plan.app;

    // 数据库连接：同步用主连接；异步在 worker 自建
    var local_db: ?db_mod.Db = null;
    const db: *db_mod.Db = if (plan.async) blk: {
        local_db = db_mod.Db.openFile(app.allocator, plan.io, plan.db_path) catch {
            plan.err = "数据库不可用";
            return;
        };
        break :blk &local_db.?;
    } else (if (app.db) |*d| d else {
        plan.err = "数据库不可用";
        return;
    });
    defer if (local_db) |*d| d.deinit();

    const range = selectCompactionRange(plan.history, plan.keep_tokens * 4) orelse return;
    const prev_summary: []const u8 = if (range.summarize_start > 1 and
        isCheckpointMessage(plan.history[range.summarize_start - 1]))
        plan.history[range.summarize_start - 1].content
    else
        "";
    const payload = buildCompactionPayload(plan.arena.allocator(), plan.history, range, prev_summary) catch {
        plan.err = "构建摘要输入失败";
        return;
    };

    // 摘要请求：一次性路由 id + 不写 prompt cache（避免污染正式会话缓存）
    var seed: [16]u8 = undefined;
    std.Io.random(plan.io, &seed);
    const fresh_hex = std.fmt.bytesToHex(seed, .lower);
    var beh = plan.behavior;
    beh.cache_key = false;
    beh.retention = .none;
    var client = ai.AI.init(app.allocator, plan.io, .{
        .api_key = plan.api_key,
        .endpoint = plan.endpoint,
        .model = plan.model,
        .session_id = &fresh_hex,
        .behavior = beh,
    });
    client.environ_map = plan.environ_map;

    const msgs = [_]ai.Message{
        .{ .role = "system", .content = compaction_system_prompt },
        .{ .role = "user", .content = payload },
    };
    var collector = SummaryCollector{ .allocator = app.allocator };
    defer collector.deinit();
    var wrapper = SummaryDeltaCtx{ .plan = plan, .collector = &collector };
    client.streamMessage(&msgs, &.{}, &app.compact_cancel, &wrapper, onSummaryDelta, null) catch |e| {
        plan.err = if (e == error.Canceled) "已取消" else @errorName(e);
        if (client.takeErrorBody()) |body| {
            defer app.allocator.free(body);
            const n = @min(body.len, plan.err_detail_buf.len);
            @memcpy(plan.err_detail_buf[0..n], body[0..n]);
            plan.err_detail_len = n;
        }
        return;
    };
    if (collector.list.items.len == 0) {
        plan.err = "摘要为空";
        return;
    }

    // 保留区首条已落库消息的 id
    var tail_start: i64 = 0;
    for (plan.history[range.retain_start..]) |m| {
        if (m.db_id > 0) {
            tail_start = m.db_id;
            break;
        }
    }
    if (tail_start == 0) {
        plan.err = "保留区消息未落库，无法记录 checkpoint";
        return;
    }

    // 摘要作为一条 role='summary' 的消息入库；checkpoint 只引用它
    const summary_msg_id = db.insertMessage(.{
        .session_id = plan.session_id,
        .role = "summary",
        .content = collector.list.items,
        .model = plan.model,
        .provider = plan.provider_name,
    }) catch 0;
    const tokens_before = estimateTokens(historyRequestBytesSlice(plan.history) + toolsSchemaBytes());
    _ = db.insertCompaction(
        plan.session_id,
        if (summary_msg_id != 0) "" else collector.list.items,
        summary_msg_id,
        tail_start,
        @intCast(tokens_before),
        plan.model,
    ) catch {
        plan.err = "写入 checkpoint 失败";
        return;
    };

    plan.compacted = true;
    plan.summarized = range.retain_start - range.summarize_start;
    plan.summary_len = collector.list.items.len;
    plan.tokens_before = tokens_before;
    plan.tail_start_id = tail_start;
}

fn compactionWorker(plan: *CompactionPlan) void {
    compactionExecute(plan);
    plan.app.compact_status.store(2, .release);
}

/// 估算 job.history 发一次请求的 token 数（优先 usage 锚点 + 增量）
fn estimateJobRequestTokens(job: *const StreamJob) usize {
    if (job.anchor_tokens > 0 and job.anchor_len <= job.history.len) {
        const inc = historyRequestBytesSlice(job.history[job.anchor_len..]);
        return @intCast(job.anchor_tokens + estimateTokens(inc));
    }
    var has_system = false;
    for (job.history) |m| {
        if (std.mem.eql(u8, m.role, "system")) {
            has_system = true;
            break;
        }
    }
    var bytes = historyRequestBytesSlice(job.history) + toolsSchemaBytes();
    if (!has_system) bytes += system_prompt.len;
    return estimateTokens(bytes);
}

/// 回合中途压缩：worker 已实时落库，整段 job.history（含当前回合）都可参与压缩。
/// 返回 true 表示发生了压缩（job.compacted_midturn 置位）。
fn compactJobHistory(job: *StreamJob, db: *db_mod.Db) bool {
    if (job.auto_compact_pct == 0 or job.context_window == 0) return false;
    if (job.history.len < 2) return false;
    const est = estimateJobRequestTokens(job);
    if (est * 100 < job.context_window * job.auto_compact_pct) return false;

    const hist = job.history;
    const keep_bytes = (if (job.keep_recent_tokens > 0) job.keep_recent_tokens else 20_000) * 4;
    const range = selectCompactionRange(hist, keep_bytes) orelse return false;

    const arena = job.arena.allocator();
    const prev_summary: []const u8 = if (range.summarize_start > 1 and
        isCheckpointMessage(hist[range.summarize_start - 1]))
        hist[range.summarize_start - 1].content
    else
        "";

    const payload = buildCompactionPayload(arena, hist, range, prev_summary) catch return false;

    // 摘要请求：一次性路由 id + 不写缓存
    var seed: [16]u8 = undefined;
    std.Io.random(job.io, &seed);
    const fresh_hex = std.fmt.bytesToHex(seed, .lower);
    var beh = job.behavior;
    beh.cache_key = false;
    beh.retention = .none;
    var client = ai.AI.init(job.app.allocator, job.io, .{
        .api_key = job.api_key,
        .endpoint = job.endpoint,
        .model = job.model,
        .session_id = &fresh_hex,
        .behavior = beh,
    });
    client.environ_map = job.environ_map;

    const msgs = [_]ai.Message{
        .{ .role = "system", .content = compaction_system_prompt },
        .{ .role = "user", .content = payload },
    };
    var collector = SummaryCollector{ .allocator = job.app.allocator };
    defer collector.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    client.streamMessage(&msgs, &.{}, &cancel, &collector, SummaryCollector.cb, null) catch return false;
    if (collector.list.items.len == 0) return false;

    // 保留区首条已落库消息的行 id（实时落库后当前回合消息也有 id）
    var tail_start: i64 = 0;
    for (hist[range.retain_start..]) |m| {
        if (m.db_id > 0) {
            tail_start = m.db_id;
            break;
        }
    }
    if (tail_start == 0) return false;

    // 摘要入库为 role='summary' 消息（worker 用自己的连接）
    const summary_msg_id = db.insertMessage(.{
        .session_id = job.session_id_num,
        .role = "summary",
        .content = collector.list.items,
        .model = job.model,
        .provider = job.provider_name,
    }) catch 0;
    _ = db.insertCompaction(
        job.session_id_num,
        if (summary_msg_id != 0) "" else collector.list.items,
        summary_msg_id,
        tail_start,
        @intCast(est),
        job.model,
    ) catch return false;

    // 重建 job.history：system + checkpoint + 保留区
    var new_hist = std.ArrayListUnmanaged(ai.Message){ .items = &.{}, .capacity = 0 };
    if (hist.len > 0 and std.mem.eql(u8, hist[0].role, "system")) {
        new_hist.append(arena, hist[0]) catch return false;
    }
    const wrapper = std.fmt.allocPrint(
        arena,
        "<conversation-checkpoint>\n（更早的对话已压缩，以下为摘要；需要细节时读取相关文件或询问用户）\n{s}\n</conversation-checkpoint>",
        .{collector.list.items},
    ) catch return false;
    new_hist.append(arena, .{ .role = "user", .content = wrapper }) catch return false;
    new_hist.appendSlice(arena, hist[range.retain_start..]) catch return false;
    job.history = new_hist.toOwnedSlice(arena) catch return false;

    job.compacted_midturn = true;
    // 旧锚点对应压缩前的前缀：失效，避免后续轮次用错估算
    job.anchor_len = 0;
    job.anchor_tokens = 0;
    return true;
}

/// 会话上下文/token 统计（compaction 调参用）
fn cmdStats(allocator: Allocator, io: Io, opt: CliOptions) u8 {
    var db = cliOpenDb(allocator, io, opt) orelse {
        cliWriteStderr(io, "无法打开数据库\n");
        return 4;
    };
    defer db.deinit();

    const sid = switch (cliResolveSessionEx(&db, opt, false)) {
        .existing, .created => |id| id,
        .not_found => {
            cliWriteStderr(io, "没有可用会话（可用 -session <id|latest> 指定）\n");
            return 4;
        },
        .invalid => {
            cliWriteStderr(io, "会话参数无效\n");
            return 2;
        },
    };
    const rows = db.loadMessages(sid) catch {
        cliWriteStderr(io, "读取消息失败\n");
        return 4;
    };
    const info = db.sessionInfo(sid) catch null;
    const checkpoint = db.latestCompaction(sid) catch null;

    // 有 checkpoint 时：请求只包含保留区，被压缩的消息不再发送
    var active: []const db_mod.MessageRow = rows;
    var compacted_count: usize = 0;
    var summary_bytes: usize = 0;
    var summary_msg_id: i64 = 0;
    if (checkpoint) |cp| {
        summary_msg_id = cp.summary_message_id;
        var start: usize = 0;
        var n: usize = 0;
        while (start < rows.len and rows[start].id < cp.tail_start_id) : (start += 1) {
            if (!std.mem.eql(u8, rows[start].role, "system")) n += 1;
        }
        compacted_count = n;
        active = rows[start..];
        var slen = cp.summary.len;
        if (summary_msg_id != 0) {
            for (rows) |r| {
                if (r.id == summary_msg_id) {
                    slen = r.content.len;
                    break;
                }
            }
        }
        summary_bytes = slen + 120; // 摘要 + 固定包裹文本的近似开销
    }

    // 按角色统计（同时估算真正进入请求的字节：assistant 还带 tool_calls 文本）
    const RoleAgg = struct { role: []const u8, count: usize = 0, bytes: usize = 0 };
    var aggs = [_]RoleAgg{
        .{ .role = "system" },
        .{ .role = "user" },
        .{ .role = "assistant" },
        .{ .role = "tool" },
        .{ .role = "other" },
    };
    var has_system = false;
    var total_bytes: usize = 0;
    var request_bytes: usize = summary_bytes;
    for (active) |r| {
        if (summary_msg_id != 0 and r.id == summary_msg_id) continue; // 摘要行由包裹文本代表
        const idx: usize = if (std.mem.eql(u8, r.role, "system")) blk: {
            has_system = true;
            break :blk 0;
        } else if (std.mem.eql(u8, r.role, "user"))
            1
        else if (std.mem.eql(u8, r.role, "assistant"))
            2
        else if (std.mem.eql(u8, r.role, "tool"))
            3
        else
            4;
        aggs[idx].count += 1;
        aggs[idx].bytes += r.content.len;
        total_bytes += r.content.len;
        request_bytes += r.content.len;
        if (idx == 2) request_bytes += r.tool_calls.len;
    }
    if (!has_system) request_bytes += system_prompt.len;

    // 工具输出明细 + 折叠模拟（只看仍在发送的）
    const Largest = struct { id: i64, tool: []const u8, bytes: usize };
    var largest = std.ArrayListUnmanaged(Largest){ .items = &.{}, .capacity = 0 };
    defer largest.deinit(allocator);
    var tool_bytes: usize = 0;
    // 折叠模拟：与实时折叠共用同一扫描器（回合保护/窗口/stub 边界）
    var fold_scan = context_mod.FoldScanner{};
    var fi: usize = active.len;
    while (fi > 0) {
        fi -= 1;
        const r = active[fi];
        if (fold_scan.feed(r.role, r.content, true) == .stop) break;
    }
    const sim = fold_scan.result();
    for (active) |r| {
        if (summary_msg_id != 0 and r.id == summary_msg_id) continue;
        if (!std.mem.eql(u8, r.role, "tool") or r.content.len == 0) continue;
        tool_bytes += r.content.len;
        largest.append(allocator, .{
            .id = r.id,
            .tool = if (r.tool_name.len > 0) r.tool_name else "-",
            .bytes = r.content.len,
        }) catch {};
    }
    std.mem.sort(Largest, largest.items, {}, struct {
        fn desc(_: void, a: Largest, b: Largest) bool {
            return a.bytes > b.bytes;
        }
    }.desc);

    // 请求估算：历史（含 system） + 工具 schema
    var schema_bytes: usize = 0;
    for (tools_mod.tool_defs) |d| schema_bytes += d.name.len + d.description.len + d.parameters.len;
    const request_est = estimateTokens(request_bytes + schema_bytes);

    // 窗口：从配置读当前模型（provider 可显式覆盖）
    var config = config_mod.Config{};
    config.loadFile(io, allocator, opt.config_path);
    defer config.deinit(allocator);
    const model = config.current_model;
    var ctx_window: u64 = if (model.len > 0) modelContextWindow(model) else 131_072;
    for (config.providers.items) |p| {
        if (std.mem.eql(u8, p.name, config.current_provider_name) and p.opt_context_window > 0) {
            ctx_window = p.opt_context_window;
        }
    }
    const pct = contextUsagePercent(request_est, ctx_window);

    const title = if (info) |i| i.title else "";

    if (opt.json) {
        const JRole = struct { role: []const u8, count: usize, bytes: usize, tokens: usize };
        const JLargest = struct { id: i64, tool: []const u8, bytes: usize };
        const JTool = struct {
            bytes: usize,
            tokens: usize,
            foldable_bytes: usize,
            foldable_tokens: usize,
            foldable_count: usize,
            protect_bytes: usize,
            min_bytes: usize,
            triggered: bool,
            largest: []const JLargest,
        };
        const J = struct {
            session_id: i64,
            title: []const u8,
            messages: usize,
            compacted_messages: usize,
            summary_bytes: usize,
            roles: []const JRole,
            tools_schema_bytes: usize,
            tools_schema_tokens: usize,
            request_estimate_tokens: usize,
            context_window: u64,
            context_used_percent: u64,
            tool_output: JTool,
        };
        var jroles = std.ArrayListUnmanaged(JRole){ .items = &.{}, .capacity = 0 };
        defer jroles.deinit(allocator);
        for (aggs) |a| {
            jroles.append(allocator, .{
                .role = a.role,
                .count = a.count,
                .bytes = a.bytes,
                .tokens = estimateTokens(a.bytes),
            }) catch {};
        }
        const top = @min(largest.items.len, 5);
        var jlargest = std.ArrayListUnmanaged(JLargest){ .items = &.{}, .capacity = 0 };
        defer jlargest.deinit(allocator);
        for (largest.items[0..top]) |l| {
            jlargest.append(allocator, .{ .id = l.id, .tool = l.tool, .bytes = l.bytes }) catch {};
        }

        const json = cliJsonWrite(allocator, J{
            .session_id = sid,
            .title = title,
            .messages = rows.len,
            .compacted_messages = compacted_count,
            .summary_bytes = summary_bytes,
            .roles = jroles.items,
            .tools_schema_bytes = schema_bytes,
            .tools_schema_tokens = estimateTokens(schema_bytes),
            .request_estimate_tokens = request_est,
            .context_window = ctx_window,
            .context_used_percent = pct,
            .tool_output = .{
                .bytes = tool_bytes,
                .tokens = estimateTokens(tool_bytes),
                .foldable_bytes = sim.foldable_bytes,
                .foldable_tokens = estimateTokens(sim.foldable_bytes),
                .foldable_count = sim.foldable_count,
                .protect_bytes = fold_protect_bytes,
                .min_bytes = fold_min_bytes,
                .triggered = sim.triggered,
                .largest = jlargest.items,
            },
        }) catch {
            cliWriteStderr(io, "JSON 序列化失败\n");
            return 4;
        };
        defer allocator.free(json);
        cliWriteStdout(io, json);
        cliWriteStdout(io, "\n");
        return 0;
    }

    var buf: [512]u8 = undefined;
    {
        const line = std.fmt.bufPrint(&buf, "会话 #{d} 「{s}」 共 {d} 条消息", .{ sid, title, rows.len }) catch "";
        cliWriteStdout(io, line);
        if (compacted_count > 0) {
            const line2 = std.fmt.bufPrint(&buf, "（已压缩 {d} 条不再发送，摘要 {d} 字节）", .{ compacted_count, summary_bytes }) catch "";
            cliWriteStdout(io, line2);
        }
        cliWriteStdout(io, "\n");
    }
    cliWriteStdout(io, "以下统计仅含仍在发送的消息：\n");
    cliWriteStdout(io, "角色          条数        字符      估算token\n");
    for (aggs) |a| {
        const line = std.fmt.bufPrint(&buf, "{s: <12} {d: >5} {d: >11} {d: >13}\n", .{
            a.role, a.count, a.bytes, estimateTokens(a.bytes),
        }) catch continue;
        cliWriteStdout(io, line);
    }
    {
        const line = std.fmt.bufPrint(&buf, "合计         {d: >5} {d: >11} {d: >13}\n", .{
            active.len, total_bytes, estimateTokens(total_bytes),
        }) catch "";
        cliWriteStdout(io, line);
    }
    {
        const line = std.fmt.bufPrint(&buf, "工具 schema  {d} 字节 ≈ {d} tok\n", .{
            schema_bytes, estimateTokens(schema_bytes),
        }) catch "";
        cliWriteStdout(io, line);
    }
    {
        var wb: [24]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "请求估算     {d} tok / 窗口 {s} = {d}%\n", .{
            request_est, formatCount(&wb, ctx_window), pct,
        }) catch "";
        cliWriteStdout(io, line);
    }
    {
        const line = std.fmt.bufPrint(&buf, "工具输出     {d} 字节 ≈ {d} tok；最大条目: ", .{
            tool_bytes, estimateTokens(tool_bytes),
        }) catch "";
        cliWriteStdout(io, line);
        const top = @min(largest.items.len, 5);
        for (largest.items[0..top], 0..) |l, i| {
            const sep = if (i + 1 < top) " | " else "\n";
            const line2 = std.fmt.bufPrint(&buf, "#{d} {s} {d}B{s}", .{ l.id, l.tool, l.bytes, sep }) catch continue;
            cliWriteStdout(io, line2);
        }
        if (top == 0) cliWriteStdout(io, "\n");
    }
    {
        const line = std.fmt.bufPrint(&buf, "折叠模拟     保护 {d}KB / 阈值 {d}KB: 可折 {d} 条 ≈ {d} 字节 ({d} tok){s}\n", .{
            fold_protect_bytes / 1024,
            fold_min_bytes / 1024,
            sim.foldable_count,
            sim.foldable_bytes,
            estimateTokens(sim.foldable_bytes),
            if (sim.triggered) " [触发]" else " [未触发]",
        }) catch "";
        cliWriteStdout(io, line);
    }
    return 0;
}

/// CLI AppState 停止时的统一清理（ask/compact 共用）
fn cliCleanupState(state: *AppState, allocator: Allocator) void {
    if (state.streamStatus() != .idle) {
        state.stream_cancel.store(true, .release);
        state.finalizeStream(null);
    }
    if (state.db) |*db| db.deinit();
    state.config.deinit(allocator);
    for (state.history.items) |m| freeMessage(allocator, m);
    state.history.deinit(allocator);
    for (state.messages.items) |m| state.freeDisplayMessage(m);
    state.messages.deinit(allocator);
    state.stream_buf.deinit(allocator);
    state.stream_reasoning_buf.deinit(allocator);
    state.clearStreamEventsLocked();
    state.stream_events.deinit(allocator);
    state.clearPendingSends();
    state.pending_sends.deinit(allocator);
    if (state.compact_status.load(.acquire) != 0) {
        state.compact_cancel.store(true, .release);
        state.finalizeCompaction();
    }
    state.compact_buf.deinit(allocator);
    state.freeModelSelectModels();
    state.input.deinit();
}

/// 应用 CLI 的 provider/model 覆盖；返回 0 成功，否则为退出码
fn cliApplyProviderOverrides(state: *AppState, allocator: Allocator, io: Io, opt: CliOptions) u8 {
    if (opt.provider.len > 0) {
        var found = false;
        for (state.config.providers.items) |p| {
            if (std.mem.eql(u8, p.name, opt.provider)) {
                found = true;
                break;
            }
        }
        if (!found) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "未找到提供商: {s}\n", .{opt.provider}) catch "未找到提供商\n";
            cliWriteStderr(io, msg);
            return 3;
        }
        state.config.setCurrentProvider(allocator, opt.provider);
    }
    if (opt.model.len > 0) state.config.setCurrentModel(allocator, opt.model);
    if (state.currentProvider() == null) {
        cliWriteStderr(io, "config.json 中没有可用提供商\n");
        return 3;
    }
    if (state.currentModel().len == 0) {
        cliWriteStderr(io, "未选择模型（可用 -model 指定）\n");
        return 3;
    }
    return 0;
}

/// 压缩上下文：生成摘要 checkpoint 并重建会话
fn cmdCompact(init: std.process.Init, opt: CliOptions) u8 {
    const allocator = init.gpa;
    const io = init.io;

    var state = AppState{};
    state.io = io;
    state.allocator = allocator;
    state.input.allocator = allocator;
    state.environ_map = init.environ_map;
    state.config.loadFile(io, allocator, opt.config_path);
    state.db = cliOpenDb(allocator, io, opt);
    if (state.db == null) {
        cliWriteStderr(io, "无法打开数据库\n");
        return 4;
    }
    defer cliCleanupState(&state, allocator);
    state.db_path = opt.db_path;

    const override_code = cliApplyProviderOverrides(&state, allocator, io, opt);
    if (override_code != 0) return override_code;

    const db = &state.db.?;
    const sid = switch (cliResolveSessionEx(db, opt, false)) {
        .existing, .created => |id| id,
        .not_found => {
            cliWriteStderr(io, "没有可用会话（可用 -session <id|latest> 指定）\n");
            return 4;
        },
        .invalid => {
            cliWriteStderr(io, "会话参数无效\n");
            return 2;
        },
    };
    state.session_id = sid;
    state.loadSessionContent(sid);
    if (opt.max_context > 0) state.context_window_override = opt.max_context;
    if (opt.keep_tokens > 0) state.keep_recent_tokens = opt.keep_tokens;

    var out = if (opt.keep_tokens == 0)
        state.runCompactionAdaptive()
    else
        state.runCompaction(opt.keep_tokens);
    if (out.err) |e| {
        cliWriteStderr(io, "压缩失败: ");
        cliWriteStderr(io, e);
        cliWriteStderr(io, "\n");
        const detail = out.errDetail();
        if (detail.len > 0) {
            cliWriteStderr(io, "服务端返回: ");
            cliWriteStderr(io, detail);
            cliWriteStderr(io, "\n");
        }
        return 4;
    }

    if (opt.json) {
        const J = struct {
            session_id: i64,
            compacted: bool,
            summarized_messages: usize,
            summary_bytes: usize,
            tokens_before: usize,
            tail_start_id: i64,
        };
        const json = cliJsonWrite(allocator, J{
            .session_id = sid,
            .compacted = out.compacted,
            .summarized_messages = out.summarized_messages,
            .summary_bytes = out.summary_len,
            .tokens_before = out.tokens_before,
            .tail_start_id = out.tail_start_id,
        }) catch {
            cliWriteStderr(io, "JSON 序列化失败\n");
            return 4;
        };
        defer allocator.free(json);
        cliWriteStdout(io, json);
        cliWriteStdout(io, "\n");
        return 0;
    }

    if (out.compacted) {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "已压缩 {d} 条消息 → 摘要 {d} 字节（压缩前约 {d} tok，保留起点 #{d}）\n", .{
            out.summarized_messages,
            out.summary_len,
            out.tokens_before,
            out.tail_start_id,
        }) catch "";
        cliWriteStdout(io, line);
    } else {
        cliWriteStdout(io, "当前内容无需压缩\n");
    }
    return 0;
}

fn cmdAsk(init: std.process.Init, opt: CliOptions) u8 {
    const allocator = init.gpa;
    const io = init.io;
    if (opt.message.len == 0) {
        cliWriteStderr(io, "ask 需要消息文本，例如: skynet ask \"你好\"\n");
        return 2;
    }

    var state = AppState{};
    state.io = io;
    state.allocator = allocator;
    state.input.allocator = allocator;
    state.environ_map = init.environ_map;
    state.config.loadFile(io, allocator, opt.config_path);
    state.db = cliOpenDb(allocator, io, opt);
    if (state.db == null) {
        cliWriteStderr(io, "无法打开数据库\n");
        return 4;
    }
    defer cliCleanupState(&state, allocator);
    state.db_path = opt.db_path;

    const override_code = cliApplyProviderOverrides(&state, allocator, io, opt);
    if (override_code != 0) return override_code;

    // 思考强度（仅本次请求，不写回配置）
    if (opt.thinking.len > 0) {
        if (!isThinkingLevel(opt.thinking)) {
            cliWriteStderr(io, "thinking 可选: off / low / high / max\n");
            return 2;
        }
        state.config.setThinking(allocator, opt.thinking);
    }

    // 会话：-new 强制新建；否则按参数解析（latest/空 不存在则新建；数字必须存在）
    const db = &state.db.?;
    const resolution = cliResolveSessionEx(db, opt, true);
    const created = switch (resolution) {
        .created => true,
        else => false,
    };
    const sid = switch (resolution) {
        .existing, .created => |id| id,
        .not_found => {
            cliWriteStderr(io, "会话不存在（数字 id 需已存在）\n");
            return 4;
        },
        .invalid => {
            cliWriteStderr(io, "会话参数无效\n");
            return 2;
        },
    };
    state.session_id = sid;
    if (created) {
        cliInitSessionRow(db, sid);
        state.appendHistory("system", system_prompt);
    } else {
        state.loadSessionContent(sid);
    }
    // CLI 覆盖：窗口大小与保留窗口（小规模测试压缩用）
    if (opt.max_context > 0) state.context_window_override = opt.max_context;
    if (opt.keep_tokens > 0) state.keep_recent_tokens = opt.keep_tokens;

    const turn_start_msgs = state.messages.items.len;
    const turn_start_hist = state.history.items.len;
    var progress = CliProgress{
        .quiet = opt.quiet,
        .stream = opt.stream,
        .show_tools = !opt.no_tools,
        .printed_msgs = turn_start_msgs,
    };

    state.askAI(opt.message);
    while (state.streamStatus() != .idle) {
        state.pumpStream();
        progress.tick(&state);
        Io.sleep(io, Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    progress.tick(&state);

    // 本轮最终回答（历史里最后一条有正文的 assistant）
    var answer: []const u8 = "";
    var tool_calls: usize = 0;
    if (turn_start_hist <= state.history.items.len) {
        for (state.history.items[turn_start_hist..]) |m| {
            if (std.mem.eql(u8, m.role, "assistant")) {
                if (m.content.len > 0) answer = m.content;
                if (m.tool_calls) |cs| tool_calls += cs.len;
            }
        }
    }

    var error_text: ?[]const u8 = null;
    if (answer.len == 0) {
        if (turn_start_msgs < state.messages.items.len) {
            for (state.messages.items[turn_start_msgs..]) |m| {
                if (std.mem.indexOf(u8, m.content, "AI 请求失败") != null) {
                    error_text = m.content;
                    break;
                }
            }
        }
        if (error_text == null) error_text = "请求失败（无回复）";
    }

    // CLI 的 usage 字段只表示本轮真实请求：估算值不输出
    if (state.usage_estimated) state.last_usage = .{};

    if (opt.json) {
        const J = struct {
            session_id: i64,
            content: []const u8,
            model: []const u8,
            input_tokens: u64,
            cached_tokens: u64,
            output_tokens: u64,
            tool_calls: usize,
            error_message: ?[]const u8 = null,
        };
        const json = cliJsonWrite(allocator, J{
            .session_id = sid,
            .content = answer,
            .model = state.currentModel(),
            .input_tokens = state.last_usage.input_tokens,
            .cached_tokens = state.last_usage.cached_tokens,
            .output_tokens = state.last_usage.output_tokens,
            .tool_calls = tool_calls,
            .error_message = error_text,
        }) catch {
            cliWriteStderr(io, "JSON 序列化失败\n");
            return 4;
        };
        defer allocator.free(json);
        cliWriteStdout(io, json);
        cliWriteStdout(io, "\n");
    } else if (answer.len > 0) {
        const shown = cliTruncate(answer, opt.max_chars);
        cliWriteStdout(io, shown);
        if (shown.len < answer.len) {
            var nb: [48]u8 = undefined;
            const note = std.fmt.bufPrint(&nb, "…[+{d} 字节]", .{answer.len - shown.len}) catch "";
            cliWriteStdout(io, note);
        }
        if (shown.len == 0 or shown[shown.len - 1] != '\n') cliWriteStdout(io, "\n");
    }

    return if (error_text != null) 4 else 0;
}

fn runCli(init: std.process.Init, args: []const []const u8) u8 {
    const allocator = init.gpa;
    const io = init.io;

    const opt = parseCliArgs(args) orelse {
        cliWriteStderr(io, "参数错误\n\n");
        cliPrintHelp(io, true);
        return 2;
    };

    if (std.mem.eql(u8, opt.command, "help") or
        std.mem.eql(u8, opt.command, "-h") or
        std.mem.eql(u8, opt.command, "--help"))
    {
        cliPrintHelp(io, false);
        return 0;
    }
    if (std.mem.eql(u8, opt.command, "sessions")) return cmdSessions(allocator, io, opt);
    if (std.mem.eql(u8, opt.command, "messages")) return cmdMessages(allocator, io, opt);
    if (std.mem.eql(u8, opt.command, "stats")) return cmdStats(allocator, io, opt);
    if (std.mem.eql(u8, opt.command, "compact")) return cmdCompact(init, opt);
    if (std.mem.eql(u8, opt.command, "new")) return cmdNew(allocator, io, opt);
    if (std.mem.eql(u8, opt.command, "ask")) return cmdAsk(init, opt);

    cliWriteStderr(io, "未知命令\n\n");
    cliPrintHelp(io, true);
    return 2;
}

test "帮助菜单：compact 会执行压缩命令（无数据库时安全报错）" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    var compact_idx: ?usize = null;
    for (help_commands, 0..) |hc, i| {
        if (std.mem.eql(u8, hc.name, "compact")) compact_idx = i;
    }
    try std.testing.expect(compact_idx != null);

    state.mode = .help_select;
    state.help_select_index = compact_idx.?;
    state.handleHelpSelectKey(.{ .code = .enter });

    // 菜单选 compact → 打开确认框（默认停在"否"，尚未执行）
    try std.testing.expectEqual(Mode.compact_confirm, state.mode);
    try std.testing.expectEqual(@as(u8, 1), state.confirm_stage);
    try std.testing.expect(!state.confirm_yes);
}

test "压缩提示文案统一为 ▣ 样式" {
    var buf: [128]u8 = undefined;
    const s = formatCompactionNotice(&buf, 8, 1602, 3352);
    try std.testing.expect(std.mem.startsWith(u8, s, "▣ 上下文已压缩"));
    try std.testing.expect(std.mem.indexOf(u8, s, "以上 8 条消息不再发送") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "1602 字节") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "3.3k tok") != null);
}

test "指令识别：/compact 不会被当成聊天发出去" {
    try std.testing.expect(isKnownCommand("compact"));
    try std.testing.expect(isCommandInput("/compact 500"));
    try std.testing.expect(isCommandInput("/compact"));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 无界面子命令（ask/new/sessions/messages/help）：不初始化终端，直接执行后退出
    {
        var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer arg_it.deinit();
        _ = arg_it.next(); // 程序名
        var arg_list = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
        defer arg_list.deinit(allocator);
        while (arg_it.next()) |a| try arg_list.append(allocator, a);
        if (arg_list.items.len > 0 and isCliCommand(arg_list.items[0])) {
            std.process.exit(runCli(init, arg_list.items));
        }
    }

    var backend = try tui.backend.init(allocator, io);
    defer backend.deinit();

    var terminal = try Terminal.init(allocator, backend.interface());
    defer terminal.deinit();

    try terminal.hideCursor();
    // 启用鼠标上报（滚轮滚动聊天）；退出时务必关闭，避免终端停留在鼠标模式
    try terminal.enableMouse();
    defer terminal.disableMouse() catch {};

    // 加载配置
    var state = AppState{};
    state.io = io;
    state.allocator = allocator;
    state.input.allocator = allocator;
    state.environ_map = init.environ_map;
    state.config.load(io, allocator);
    // 模糊宽度策略（①←≤…按 1 列还是 2 列）：必须在首次绘制前应用
    applyAmbiguousWidth(&state);

    // 打开数据库并恢复/新建会话
    var db_ok = true;
    state.db = db_mod.Db.open(allocator, io) catch blk: {
        db_ok = false;
        break :blk null;
    };
    if (state.db) |*db| {
        const latest = db.latestSession() catch null;
        if (latest) |s| {
            state.loadSessionContent(s.id);
        } else {
            state.session_id = db.createSession("") catch 0;
            _ = db.insertMessage(.{ .session_id = state.session_id, .role = "system", .content = system_prompt }) catch {};
            state.appendHistory("system", system_prompt);
        }
    } else {
        // 数据库不可用时退化为纯内存模式
        state.appendHistory("system", system_prompt);
    }
    // 启动即显示上下文估算（加载路径里也会刷新）
    state.refreshEstimatedUsage();

    // 清理过期的 bash 截断临时文件（保留最近 7 天：会话历史里的 stub 可能仍引用）
    _ = tools_mod.cleanupStaleBashTempFiles(
        io,
        init.environ_map,
        std.Io.Timestamp.now(io, .awake).toMilliseconds(),
        7 * 24 * 60 * 60 * 1000,
    );

    if (state.config.providers.items.len > 0) {
        if (state.config.current_model.len > 0) {
            if (state.currentProviderIndex()) |idx| {
                state.addRecentModel(idx, state.config.current_model);
            }
        }
    } else {
        state.addMessage("尚无提供商，输入 /models 后按 Ctrl+A 添加", .{ .fg = .dark_gray });
    }
    if (!db_ok) {
        state.addMessage("警告: 数据库打开失败，本次对话不会持久化", .{ .fg = .red });
    }
    defer {
        // 生成中退出：中断并等待线程结束，保留已生成内容
        if (state.streamStatus() != .idle) {
            state.stream_cancel.store(true, .release);
            state.finalizeStream(null);
        }
        if (state.db) |*db| db.deinit();
        state.config.deinit(state.allocator);
        for (state.history.items) |msg| {
            freeMessage(state.allocator, msg);
        }
        state.history.deinit(state.allocator);
        for (state.messages.items) |msg| {
            state.freeDisplayMessage(msg);
        }
        state.messages.deinit(state.allocator);
        state.stream_buf.deinit(state.allocator);
        state.stream_reasoning_buf.deinit(state.allocator);
        state.clearStreamEventsLocked();
        state.stream_events.deinit(state.allocator);
        state.clearPendingSends();
        state.pending_sends.deinit(state.allocator);
        // 压缩线程：取消并收尾后释放缓冲
        if (state.compact_status.load(.acquire) != 0) {
            state.compact_cancel.store(true, .release);
            state.finalizeCompaction();
        }
        state.compact_buf.deinit(state.allocator);
        state.freeModelSelectModels();
        state.input.deinit();
    }

    while (state.running) {
        // 流式回复：取出增量、检测结束
        if (state.streamStatus() != .idle) state.pumpStream();
        // 异步压缩：消费摘要增量 / 完成收尾
        state.pumpCompaction();

        // 其他进程（CLI）写入当前会话时增量刷新
        state.pollExternalUpdates();

        // 边缘拖动自动滚动：先滚动，绘制后用新行映射重算选区端点
        var did_autoscroll = false;
        if (state.auto_scroll_dir != 0) {
            switch (state.sel_area) {
                .messages => {
                    if (state.auto_scroll_dir < 0) {
                        state.scroll_offset +|= 1; // 向更早的内容滚动
                    } else {
                        state.scroll_offset -|= 1; // 向更新的内容滚动
                    }
                },
                .input => {
                    state.input.scrollView(
                        state.auto_scroll_dir < 0,
                        state.input_wrap_width,
                        state.input_content_rows,
                    );
                },
            }
            did_autoscroll = true;
        }

        // 自动滚动期间缩短轮询间隔；流式输出期间保持高刷新率
        const poll_timeout: u32 = if (state.auto_scroll_dir != 0)
            30
        else if (state.isStreaming() or state.isCompacting())
            16
        else
            80;

        // 先绘制再等待事件：sel_rows 里保存的是指向消息内容的指针，
        // 而下一轮开头的 pumpStream 会重分配内容。若在事件之后再绘制，
        // 鼠标命中测试就会用到悬空的行映射（流式输出时点鼠标会崩溃）。
        const Ctx = struct { s: *AppState };
        try terminal.draw(Ctx{ .s = &state }, struct {
            fn render(ctx: Ctx, buf: *Buffer) !void {
                drawFrame(ctx.s, buf);
            }
        }.render);

        if (did_autoscroll) {
            state.refreshDragSelection();
        }

        // 一次绘制后连续排空已缓冲的事件：快速拖动鼠标时终端会按字符格逐个
        // 上报移动事件（一次读取里排入多个），若每帧只处理一个，选中高亮就会
        // 逐个事件"追赶"鼠标。首个事件按 poll_timeout 等待，其余非阻塞取走；
        // resize 会重排终端缓冲，处理完立即跳出本帧（下帧重绘后继续）。
        var wait_ms = poll_timeout;
        var drained: usize = 0;
        while (drained < max_events_per_frame) : (drained += 1) {
            const event = try backend.interface().pollEvent(wait_ms);
            wait_ms = 0;
            if (event == .none) break;
            try handleTerminalEvent(&state, &terminal, event);
            if (event == .resize) break;
        }
    }

    try terminal.showCursor();
}

/// 处理单个终端事件（从 runTui 主循环抽出：主循环一次绘制后批量排空事件，
/// 见那里的排空注释；本函数只做分发与状态更新）。
fn handleTerminalEvent(state: *AppState, terminal: *Terminal, event: tui.Event) !void {
    switch (event) {
        .key => |key| {
            // 按键重置光标闪烁相位（保持短暂实心）
            state.blink_anchor_ms = std.Io.Timestamp.now(state.io, .awake).toMilliseconds();
            switch (state.mode) {
                .model_select => state.handleModelSelectKey(key),
                .provider_models => state.handleProviderModelsKey(key),
                .provider_add => state.handleProviderAddKey(key),
                .provider_confirm => state.handleProviderConfirmKey(key),
                .compact_confirm => state.handleCompactConfirmKey(key),
                .thinking_select => state.handleThinkingSelectKey(key),
                .preset_select => state.handlePresetSelectKey(key),
                .session_select => state.handleSessionSelectKey(key),
                .session_confirm => state.handleSessionConfirmKey(key),
                .help_select => state.handleHelpSelectKey(key),
                else => state.handleNormalKey(key),
            }
        },
        .paste => |text| {
            // 终端包裹的粘贴内容（bracketed paste）：替换选中内容并插入
            switch (state.mode) {
                .normal => {
                    if (state.sel_active) {
                        if (state.sel_area == .input) {
                            state.deleteInputSelection();
                        } else {
                            state.clearSelection();
                        }
                    }
                    const inserted = insertPastedText(state.allocator, &state.input, text);
                    if (inserted < text.len) {
                        state.setToast("粘贴内容超过输入框上限，已截断");
                    }
                },
                .provider_add => {
                    // 表单字段同样支持粘贴（密钥/地址通常靠粘贴输入）
                    const inserted = insertPastedText(state.allocator, state.providerFormActiveInput(), text);
                    if (inserted < text.len) {
                        state.setToast("粘贴内容超过字段上限，已截断");
                    }
                },
                else => {},
            }
        },
        .mouse => |m| {
            if (state.mode == .normal) {
                switch (m.kind) {
                    .down => {
                        if (m.button == .left) {
                            if (thoughtRowAt(state, m.y)) |tmsg| {
                                toggleThought(state, tmsg);
                            } else if (state.pointFromScreenStrict(m.x, m.y)) |p| {
                                state.sel_area = .messages;
                                state.sel_anchor = p;
                                state.sel_current = p;
                                state.sel_active = true;
                                state.sel_dragging = true;
                                state.drag_x = m.x;
                                state.drag_y = m.y;
                                state.auto_scroll_dir = 0;
                            } else if (state.pointFromInputStrict(m.x, m.y)) |p| {
                                // 单击定位输入光标（不改变视口），同时作为选区锚点
                                state.input.setCursor(p.off);
                                state.blink_anchor_ms = std.Io.Timestamp.now(state.io, .awake).toMilliseconds();
                                state.sel_area = .input;
                                state.sel_anchor = p;
                                state.sel_current = p;
                                state.sel_active = true;
                                state.sel_dragging = true;
                                state.drag_x = m.x;
                                state.drag_y = m.y;
                                state.auto_scroll_dir = 0;
                            } else {
                                state.clearSelection();
                            }
                        }
                    },
                    .moved => {
                        if (state.sel_dragging) {
                            state.drag_x = m.x;
                            state.drag_y = m.y;
                            const p = switch (state.sel_area) {
                                .messages => state.pointFromScreen(m.x, m.y),
                                .input => state.pointFromInputClamped(m.x, m.y),
                            };
                            if (p) |pt| state.sel_current = pt;
                            state.updateAutoScrollDir();
                        }
                    },
                    .up => {
                        if (state.sel_dragging) {
                            state.stopDragging();
                            // 单击（未拖动）视为清除选择
                            if (state.sel_anchor.msg == state.sel_current.msg and
                                state.sel_anchor.source == state.sel_current.source and
                                state.sel_anchor.off == state.sel_current.off)
                            {
                                state.clearSelection();
                            }
                        }
                    },
                    .scroll_up => {
                        // 滚轮按鼠标所在区域路由：输入框上方滚输入框，否则滚消息
                        if (state.input_box_top > 0 and m.y >= state.input_box_top) {
                            state.input.scrollView(true, state.input_wrap_width, state.input_content_rows);
                        } else {
                            state.scroll_offset +|= 3;
                        }
                    },
                    .scroll_down => {
                        if (state.input_box_top > 0 and m.y >= state.input_box_top) {
                            state.input.scrollView(false, state.input_wrap_width, state.input_content_rows);
                        } else {
                            state.scroll_offset -|= 3;
                        }
                    },
                    else => {},
                }
            }
        },
        .resize => |size| {
            try terminal.resize(.{ .width = size.width, .height = size.height });
            state.terminal_height = size.height;
        },
        else => {},
    }
}

/// 复制字符串并清洗非法 UTF-8（输入合法时等价于 dupe）
fn sanitizeDup(allocator: Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return allocator.dupe(u8, s);
    return ai.sanitizeUtf8(allocator, s);
}

/// 工具调用 → JSON 文本（落库用）
fn toolCallsToJson(allocator: Allocator, calls: []const ai.ToolCall) error{OutOfMemory}![]u8 {
    const Raw = struct { id: []const u8, name: []const u8, arguments: []const u8 };
    const list = try allocator.alloc(Raw, calls.len);
    defer allocator.free(list);
    for (calls, 0..) |c, i| {
        list[i] = .{ .id = c.id, .name = c.name, .arguments = c.arguments };
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    std.json.Stringify.value(list, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// 解析落库的工具调用 JSON 文本；失败返回 null
fn parseToolCalls(allocator: Allocator, json: []const u8) ?[]ai.ToolCall {
    if (json.len == 0) return null;
    const Raw = struct { id: []const u8 = "", name: []const u8 = "", arguments: []const u8 = "" };
    const parsed = std.json.parseFromSliceLeaky([]Raw, allocator, json, .{ .ignore_unknown_fields = true }) catch return null;
    const list = allocator.alloc(ai.ToolCall, parsed.len) catch return null;
    for (parsed, 0..) |r, i| {
        list[i] = .{ .id = r.id, .name = r.name, .arguments = r.arguments };
    }
    return list;
}

/// 恢复工具调用提示行（非块类工具，如 ls/read/grep）
fn addLoadedToolCallNote(self: *AppState, arena: Allocator, name: []const u8, args: []const u8) void {
    const line = formatToolCallLine(arena, name, args);
    self.addMessage(line, tool_call_style);
}

/// 恢复一条工具结果：块类工具（bash/edit）重建工具块，其余回填统计或补错误行。
/// 若该结果已被折叠（content=stub、tool_full=全文），展示仍用全文。
fn addLoadedToolDisplay(self: *AppState, arena: Allocator, name: []const u8, args: []const u8, line_idx: ?usize, row: db_mod.MessageRow) void {
    const display_text: []const u8 = if (row.tool_full.len > 0) row.tool_full else row.content;
    if (name.len > 0) {
        if (toolBlockKind(name)) |kind| {
            const header = toolHeaderText(arena, name, args) orelse name;
            // 正文：edit → 落库的 diff；shell → 原始输出；错误 → 错误文本
            const raw: []const u8 = if (row.is_error != 0)
                display_text
            else if (row.tool_display.len > 0)
                row.tool_display
            else
                display_text;
            const max_lines: usize = if (kind == .diff) 40 else 20;
            const capped = capBlockBody(self.allocator, raw, max_lines) catch null;
            defer if (capped) |c| self.allocator.free(c);
            const body: []const u8 = if (capped) |c| c else raw;
            const joined = std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ header, body }) catch return;
            self.messages.append(self.allocator, .{
                .content = joined,
                .style = .{ .fg = .white },
                .tool_block = kind,
                .tool_error = row.is_error != 0,
            }) catch {
                self.allocator.free(joined);
                return;
            };
            self.scroll_offset = 0;
            return;
        }
    }

    // 非块工具：成功回填大小统计到调用行；失败补红色错误行
    if (row.is_error == 0) {
        const result = tools_mod.Result{ .content = @constCast(display_text), .is_error = false };
        const summary = summarizeToolResult(arena, result) catch "";
        if (line_idx) |idx| self.appendNoteSuffixAt(idx, summary);
        return;
    }
    const result = tools_mod.Result{ .content = @constCast(display_text), .is_error = true };
    const summary = summarizeToolResult(arena, result) catch "";
    var buf: [320]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "↳ 失败{s}{s}", .{
        if (summary.len > 0) " · " else "",
        summary,
    }) catch "↳ 失败";
    self.addMessage(line, .{ .fg = .red });
}

/// 工具 → 块渲染类型（仅 bash/edit 使用块渲染）
fn toolBlockKind(name: []const u8) ?ToolBlockKind {
    if (std.mem.eql(u8, name, "bash")) return .shell;
    if (std.mem.eql(u8, name, "edit")) return .diff;
    return null;
}

/// 从参数 JSON 中取字符串字段
fn extractJsonString(arena: Allocator, args_json: []const u8, field: []const u8) ?[]const u8 {
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
fn extractJsonInt(arena: Allocator, args_json: []const u8, field: []const u8) ?i64 {
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
fn extractJsonBool(arena: Allocator, args_json: []const u8, field: []const u8) bool {
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

fn formatBytes(buf: []u8, len: usize) []const u8 {
    if (len < 1024) return std.fmt.bufPrint(buf, "{d}B", .{len}) catch "?";
    const kb100 = (len * 10) / 1024;
    return std.fmt.bufPrint(buf, "{d}.{d}KB", .{ kb100 / 10, kb100 % 10 }) catch "?";
}

/// token 数量的紧凑显示（1.2k / 3.4M）
fn formatCount(buf: []u8, n: u64) []const u8 {
    if (n < 1000) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    if (n < 1_000_000) {
        const scaled = n / 100;
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ scaled / 10, scaled % 10 }) catch "?";
    }
    const scaled = n / 100_000;
    return std.fmt.bufPrint(buf, "{d}.{d}M", .{ scaled / 10, scaled % 10 }) catch "?";
}

/// 模型上下文窗口大小（/models 不返回该信息，按模型名启发式匹配）
fn modelContextWindow(model: []const u8) u64 {
    const Entry = struct { needle: []const u8, ctx: u64 };
    const table = [_]Entry{
        .{ .needle = "gpt-4.1", .ctx = 1_047_576 },
        .{ .needle = "gpt-4o", .ctx = 128_000 },
        .{ .needle = "gpt-4", .ctx = 128_000 },
        .{ .needle = "gpt-5", .ctx = 400_000 },
        .{ .needle = "o3", .ctx = 200_000 },
        .{ .needle = "o4", .ctx = 200_000 },
        .{ .needle = "deepseek-v4", .ctx = 1_048_576 },
        .{ .needle = "deepseek", .ctx = 128_000 },
        .{ .needle = "kimi", .ctx = 256_000 },
        .{ .needle = "moonshot", .ctx = 128_000 },
        .{ .needle = "glm", .ctx = 128_000 },
        .{ .needle = "qwen", .ctx = 131_072 },
        .{ .needle = "gemini", .ctx = 1_048_576 },
        .{ .needle = "grok", .ctx = 256_000 },
        .{ .needle = "minimax", .ctx = 204_800 },
        .{ .needle = "llama", .ctx = 131_072 },
        .{ .needle = "mistral", .ctx = 131_072 },
        .{ .needle = "claude", .ctx = 200_000 },
    };
    for (table) |e| {
        if (std.ascii.indexOfIgnoreCase(model, e.needle) != null) return e.ctx;
    }
    return 131_072;
}

fn contextUsagePercent(used: u64, ctx: u64) u64 {
    if (ctx == 0) return 0;
    return @min(used * 100 / ctx, 999);
}

// ── 模糊宽度（config.json: ambiguous_width）──
// EAW=Ambiguous 字符（①←≤…等）的排版策略，三档：
//   auto（默认） = 窄基底 + 内置推荐名单（明显被单格字形挤压的字符族按 2 列）
//   wide         = 纯 2 列（渲染层自动补续格，CJK 传统）
//   narrow       = 纯 1 列（opencode/string-width 等生态默认）
// 用户的 width_overrides 永远最高优先（想抵消 auto 的加宽就写进 narrow 名单）。

const AmbiguousMode = enum { auto, wide, narrow };

/// 档位解析：显式 wide/narrow；""/"auto" 及未知值一律按 auto
fn parseAmbiguousMode(mode: []const u8) AmbiguousMode {
    if (std.mem.eql(u8, mode, "wide")) return .wide;
    if (std.mem.eql(u8, mode, "narrow")) return .narrow;
    return .auto;
}

const AutoWideRange = struct { lo: u21, hi: u21 };

/// auto 档内置的「推荐宽字符」名单（由项目作者长期维护：
/// 以后发现「单格字形被挤压」的字符族，直接往这里加范围即可）。
/// 仅 auto 档生效；显式 wide/narrow 是纯档位、不叠加本名单；
/// 用户 width_overrides（含 narrow）永远优先于本名单。
const auto_recommended_wide = [_]AutoWideRange{
    // 带圈/带括号数字与字母（①-⑳、⑴-⒇、⒈-⒛ 及 ⒜-ⓩ、⓵-⓿；含 ⓪——官方
    // EAW=N，但同族字形，一并加宽保持一致）。单格渲染时圈圈明显相叠，默认加宽修正。
    .{ .lo = 0x2460, .hi = 0x24FF },
    // 候选（暂未启用）：U+1F100-U+1F10A「数字+句点」补充面组合，出现频率低。
};

/// 应用模糊宽度档位与覆盖名单到渲染层（TUI 启动时调用一次）
fn applyAmbiguousWidth(state: *AppState) void {
    const mode = parseAmbiguousMode(state.config.ambiguous_width);
    tui.render.width_mod.ambiguous_width = switch (mode) {
        .wide => .wide,
        .narrow, .auto => .narrow, // auto 基底为窄，靠推荐名单做定向加宽
    };

    // 用户覆盖名单（可只配一侧；空名单即清空）
    var wide_list: std.ArrayListUnmanaged(u21) = .{ .items = &.{}, .capacity = 0 };
    defer wide_list.deinit(state.allocator);
    var narrow_list: std.ArrayListUnmanaged(u21) = .{ .items = &.{}, .capacity = 0 };
    defer narrow_list.deinit(state.allocator);
    parseWidthOverrides(state.allocator, state.config.width_overrides_wide, &wide_list);
    parseWidthOverrides(state.allocator, state.config.width_overrides_narrow, &narrow_list);

    // auto：叠加内置推荐名单；用户 narrow 名单优先（冲突的条目不加入）
    if (mode == .auto) appendAutoRecommended(state.allocator, &wide_list, narrow_list.items);

    tui.render.width_mod.setWidthOverrides(wide_list.items, narrow_list.items);
}

/// 把内置推荐名单追加进 wide 名单（渲染层上限截断；用户 narrow 名单里的字符跳过）
fn appendAutoRecommended(allocator: Allocator, wide_list: *std.ArrayListUnmanaged(u21), user_narrow: []const u21) void {
    const max = tui.render.width_mod.max_width_overrides;
    for (auto_recommended_wide) |r| {
        var cp: u32 = r.lo;
        while (cp <= r.hi) : (cp += 1) {
            const c: u21 = @intCast(cp);
            if (user_narrow.len > 0 and std.mem.indexOfScalar(u21, user_narrow, c) != null) continue;
            if (wide_list.items.len >= max) return;
            wide_list.append(allocator, c) catch return;
        }
    }
}

/// 解析宽度覆盖名单（config.json 的 width_overrides.wide/narrow）：
/// 空白/逗号分隔的 token，支持 "U+XXXX"（单点）、"U+XXXX-U+YYYY"（范围，U+ 前缀可省）
/// 或字面字符（每个 UTF-8 字符分别计入）。非法 token 跳过；总量封顶在渲染层上限。
fn parseWidthOverrides(allocator: Allocator, spec: []const u8, out: *std.ArrayListUnmanaged(u21)) void {
    const max = tui.render.width_mod.max_width_overrides;
    var it = std.mem.tokenizeAny(u8, spec, " ,\t\r\n");
    while (it.next()) |tok| {
        if (out.items.len >= max) return;
        if (tok.len >= 3 and (tok[0] == 'U' or tok[0] == 'u') and tok[1] == '+') {
            const body = tok[2..];
            if (std.mem.indexOfScalar(u8, body, '-')) |dash| {
                const lo = std.fmt.parseInt(u21, body[0..dash], 16) catch continue;
                var hi_part = body[dash + 1 ..];
                if (hi_part.len >= 3 and (hi_part[0] == 'U' or hi_part[0] == 'u') and hi_part[1] == '+') {
                    hi_part = hi_part[2..];
                }
                const hi = std.fmt.parseInt(u21, hi_part, 16) catch continue;
                var cp: u32 = lo;
                while (cp <= hi) : (cp += 1) {
                    if (out.items.len >= max) return;
                    out.append(allocator, @intCast(cp)) catch return;
                }
            } else {
                const cp = std.fmt.parseInt(u21, body, 16) catch continue;
                out.append(allocator, cp) catch return;
            }
        } else {
            // 字面字符 token：每个 UTF-8 字符加入名单
            var i: usize = 0;
            while (i < tok.len) {
                const len = std.unicode.utf8ByteSequenceLength(tok[i]) catch 1;
                if (i + len > tok.len) break;
                const cp = std.unicode.utf8Decode(tok[i .. i + len]) catch {
                    i += 1;
                    continue;
                };
                if (out.items.len >= max) return;
                out.append(allocator, cp) catch return;
                i += len;
            }
        }
    }
}

/// 缓存命中率百分比（cached/input，越高越好）
fn cacheHitPercent(cached: u64, input: u64) u64 {
    if (input == 0) return 0;
    return @min(cached * 100 / input, 100);
}

fn appendToolOpt(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) void {
    if (list.items.len > 0) list.appendSlice(allocator, ", ") catch return;
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    list.appendSlice(allocator, s) catch {};
}

/// 工具调用单行描述（`→ Read path [limit=.., offset=..]`）
fn formatToolCallLine(arena: Allocator, name: []const u8, args_json: []const u8) []const u8 {
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

/// 工具调用行样式（橙色）
const tool_call_style = Style{ .fg = .{ .rgb = .{ .r = 235, .g = 155, .b = 60 } } };

/// 块标题行：`$ 命令` / `← Edit 路径`
fn toolHeaderText(arena: Allocator, name: []const u8, args_json: []const u8) ?[]const u8 {
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

/// 截断块正文到 max_lines 行，超出用 `…` 收尾
fn capBlockBody(allocator: Allocator, body: []const u8, max_lines: usize) error{OutOfMemory}![]u8 {
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

/// 工具块按 '\n' 取一行（不自动换行）
fn nextBlockLine(content: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= content.len) return null;
    const start = pos.*;
    const nl = std.mem.indexOfScalarPos(u8, content, start, '\n');
    const end = nl orelse content.len;
    pos.* = if (nl) |n| n + 1 else content.len;
    return content[start..end];
}

fn countBlockLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

/// shell 块标题最多折行数（超出用 … 收尾）
const shell_header_max_rows: usize = 6;

/// 工具块占用的行数：shell 折行，diff 不折行
fn countBlockRows(content: []const u8, kind: ToolBlockKind, width: usize) usize {
    if (kind == .diff) return countBlockLines(content);

    var total: usize = 0;
    var pos: usize = 0;
    var line_index: usize = 0;
    while (nextBlockLine(content, &pos)) |text| {
        var rows = countVisualLines(text, width);
        if (rows == 0) rows = 1; // 空行也占一行
        if (line_index == 0) rows = @min(rows, shell_header_max_rows);
        total += rows;
        line_index += 1;
    }
    return total;
}

const DiffLineKind = enum { context, removed, added, elide };

/// 展示行格式为 "{行号:>5} {标记} {内容}"（见 tools.zig appendNumberedLine）。
/// 必须按固定位置解析标记：内容自身可能以 "- " 开头（如 markdown 列表），
/// 对前几个字节搜子串 " - "/" + " 会把这类行误判成删除/新增。
fn diffLineKind(text: []const u8) DiffLineKind {
    if (std.mem.startsWith(u8, text, "     …")) return .elide;
    // 跳过行号：前导空格 + 数字 + 一个空格，随后是标记字符（' '/'-'/'+'）
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i < text.len and text[i] == ' ') i += 1;
    if (i < text.len) {
        if (text[i] == '-') return .removed;
        if (text[i] == '+') return .added;
    }
    return .context;
}

/// 绘制工具块的一行：整行铺底色，按类型着色
fn drawToolBlockRow(
    state: *AppState,
    buf: *Buffer,
    area: Rect,
    msg_idx: usize,
    content: []const u8,
    text: []const u8,
    line_index: usize,
    kind: ToolBlockKind,
    is_error: bool,
    y: u16,
) void {
    const block_bg = Style{ .bg = .{ .rgb = .{ .r = 20, .g = 20, .b = 20 } } };

    var style = block_bg;
    if (line_index == 0) {
        style.fg = if (is_error) .red else .light_cyan;
        style.modifier = .{ .bold = true };
    } else switch (kind) {
        .shell => style.fg = .gray,
        .diff => switch (diffLineKind(text)) {
            .added => {
                style.bg = .{ .rgb = .{ .r = 20, .g = 60, .b = 30 } };
                style.fg = .light_white;
            },
            .removed => {
                style.bg = .{ .rgb = .{ .r = 70, .g = 20, .b = 30 } };
                style.fg = .light_white;
            },
            .elide, .context => style.fg = .dark_gray,
        },
    }

    // 用本行底色铺满整行（新增/删除行的底色横向贯通）
    var x = area.x;
    while (x < area.x +| area.width) : (x += 1) buf.setChar(x, y, ' ', style);

    _ = buf.putString(area.x, y, text, area.width, style);
    recordPlainRow(state, msg_idx, content, text, area.x, y);
}

fn cloneMessage(allocator: Allocator, m: ai.Message) error{OutOfMemory}!ai.Message {
    var out = ai.Message{
        .role = try sanitizeDup(allocator, m.role),
        .content = try sanitizeDup(allocator, m.content),
        .db_id = m.db_id,
    };
    errdefer {
        allocator.free(out.role);
        allocator.free(out.content);
    }
    if (m.tool_call_id) |id| {
        out.tool_call_id = try sanitizeDup(allocator, id);
    }
    if (m.tool_calls) |calls| {
        const list = try allocator.alloc(ai.ToolCall, calls.len);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |c| freeToolCall(allocator, c);
            allocator.free(list);
        }
        for (calls, 0..) |c, i| {
            list[i] = .{
                .id = try sanitizeDup(allocator, c.id),
                .name = try sanitizeDup(allocator, c.name),
                .arguments = try sanitizeDup(allocator, c.arguments),
            };
            filled = i + 1;
        }
        out.tool_calls = list;
    }
    return out;
}

fn freeToolCall(allocator: Allocator, c: ai.ToolCall) void {
    allocator.free(c.id);
    allocator.free(c.name);
    allocator.free(c.arguments);
}

fn freeMessage(allocator: Allocator, m: ai.Message) void {
    allocator.free(m.role);
    allocator.free(m.content);
    if (m.tool_call_id) |id| allocator.free(id);
    if (m.tool_calls) |calls| {
        for (calls) |c| freeToolCall(allocator, c);
        allocator.free(calls);
    }
}

/// 扩展 history（arena 分配，旧内容复用）
fn extendHistory(arena: Allocator, old: []const ai.Message, items: []const ai.Message) error{OutOfMemory}![]ai.Message {
    const out = try arena.alloc(ai.Message, old.len + items.len);
    @memcpy(out[0..old.len], old);
    @memcpy(out[old.len..], items);
    return out;
}

fn cloneToolCalls(arena: Allocator, calls: []const ai.ToolCall) error{OutOfMemory}![]ai.ToolCall {
    const out = try arena.alloc(ai.ToolCall, calls.len);
    for (calls, 0..) |c, i| {
        out[i] = .{
            .id = try arena.dupe(u8, c.id),
            .name = try arena.dupe(u8, c.name),
            .arguments = try arena.dupe(u8, c.arguments),
        };
    }
    return out;
}

/// 把当前回合（正文 + 工具调用 + 思考）写入转录并扩展 history
fn appendAssistantTurn(job: *StreamJob, arena: Allocator, calls: []const ai.ToolCall) error{OutOfMemory}!void {
    const msg = ai.Message{
        .role = "assistant",
        .content = try arena.dupe(u8, job.content.items),
        .tool_calls = if (calls.len > 0) try cloneToolCalls(arena, calls) else null,
    };
    const entry = TranscriptEntry{
        .msg = msg,
        .reasoning = try arena.dupe(u8, job.reasoning.items),
        .reasoning_ms = if (job.reasoning_end_ms > job.reasoning_start_ms)
            job.reasoning_end_ms - job.reasoning_start_ms
        else
            0,
        .usage = job.round_usage,
    };
    try job.transcript.append(arena, entry);
    job.history = try extendHistory(arena, job.history, &[_]ai.Message{msg});
}

/// 工具调用参数摘要（key=value 形式，截断到 ~120 字符）
fn summarizeToolArgs(arena: Allocator, args_json: []const u8) error{OutOfMemory}![]const u8 {
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

/// 工具结果摘要（错误取首行，成功给大小）
fn summarizeToolResult(arena: Allocator, result: tools_mod.Result) error{OutOfMemory}![]const u8 {
    const nl = std.mem.indexOfScalar(u8, result.content, '\n') orelse result.content.len;
    if (result.is_error) {
        var line = result.content[0..nl];
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
    return std.fmt.allocPrint(arena, "{s}", .{formatBytes(&size_buf, result.content.len)});
}

/// 事件入队（线程安全）
fn pushStreamEvent(
    app: *AppState,
    kind: StreamEventKind,
    name: []const u8,
    text: []const u8,
    args: []const u8,
    payload: []const u8,
    is_error: bool,
) void {
    app.stream_mutex.lockUncancelable(app.io);
    defer app.stream_mutex.unlock(app.io);
    const name_copy = app.allocator.dupe(u8, name) catch return;
    const text_copy = app.allocator.dupe(u8, text) catch {
        app.allocator.free(name_copy);
        return;
    };
    const args_copy = app.allocator.dupe(u8, args) catch {
        app.allocator.free(name_copy);
        app.allocator.free(text_copy);
        return;
    };
    const payload_copy = app.allocator.dupe(u8, payload) catch {
        app.allocator.free(name_copy);
        app.allocator.free(text_copy);
        app.allocator.free(args_copy);
        return;
    };
    app.stream_events.append(app.allocator, .{
        .kind = kind,
        .name = name_copy,
        .text = text_copy,
        .args = args_copy,
        .payload = payload_copy,
        .is_error = is_error,
    }) catch {
        app.allocator.free(name_copy);
        app.allocator.free(text_copy);
        app.allocator.free(args_copy);
        app.allocator.free(payload_copy);
    };
}

/// 等待主线程消费完正文/思考/事件，保证显示顺序（回合边界与工具阶段前后调用）
fn waitDrained(app: *AppState) void {
    while (true) {
        if (app.stream_cancel.load(.acquire)) return;
        app.stream_mutex.lockUncancelable(app.io);
        const drained = app.stream_consume_pos >= app.stream_buf.items.len and
            app.stream_reasoning_pos >= app.stream_reasoning_buf.items.len and
            app.stream_events.items.len == 0;
        app.stream_mutex.unlock(app.io);
        if (drained) return;
        Io.sleep(app.io, Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
}

/// 把转录中的一条消息立即落库（实时落库：程序意外退出也不会丢已产出的消息）。
/// 成功时把行 id 写回转录条目与 job.history 对应位置（供回合中途压缩取 tail 边界）。
/// 数据库不可用或写入失败时静默跳过：finalize 会按 db_id == 0 重试批量落库。
fn persistTranscriptEntry(job: *StreamJob, db: *db_mod.Db, entry_idx: usize, hist_idx: usize) void {
    if (entry_idx >= job.transcript.items.len or hist_idx >= job.history.len) return;
    const entry = &job.transcript.items[entry_idx];
    const m = &entry.msg;
    if (m.db_id != 0) return;

    const arena = job.arena.allocator();
    var calls_json: []const u8 = "";
    if (m.tool_calls) |calls| {
        calls_json = toolCallsToJson(arena, calls) catch "";
    }
    // 工具结果：取出渲染元数据（工具名 / diff 正文 / 错误标志）
    var t_name: []const u8 = "";
    var t_display: []const u8 = "";
    var t_error: i64 = 0;
    if (std.mem.eql(u8, m.role, "tool")) {
        if (m.tool_call_id) |cid| {
            for (job.tool_meta.items) |tm| {
                if (std.mem.eql(u8, tm.id, cid)) {
                    t_name = tm.name;
                    t_display = tm.display;
                    t_error = if (tm.is_error) 1 else 0;
                    break;
                }
            }
        }
    }
    const id = db.insertMessage(.{
        .session_id = job.session_id_num,
        .role = m.role,
        .content = m.content,
        .model = job.model,
        .provider = job.provider_name,
        .reasoning = entry.reasoning,
        .reasoning_ms = entry.reasoning_ms,
        .tool_calls = calls_json,
        .tool_call_id = m.tool_call_id orelse "",
        .tool_name = t_name,
        .tool_display = t_display,
        .tool_full = "",
        .is_error = t_error,
        .input_tokens = @intCast(entry.usage.input_tokens),
        .cached_tokens = @intCast(entry.usage.cached_tokens),
        .output_tokens = @intCast(entry.usage.output_tokens),
    }) catch return;
    if (id == 0) return;
    entry.msg.db_id = id;
    job.history[hist_idx].db_id = id;
}

/// 取（必要时打开）worker 自己的数据库连接；不可用时返回 null（回退到 finalize 批量落库）
fn ensureWorkerDb(job: *StreamJob, slot: *?db_mod.Db) ?*db_mod.Db {
    if (slot.*) |*d| return d;
    if (job.db_path.len == 0 or job.session_id_num == 0) return null;
    if (std.mem.eql(u8, job.db_path, ":memory:")) return null;
    slot.* = db_mod.Db.openFile(job.app.allocator, job.io, job.db_path) catch return null;
    return &slot.*.?;
}

/// 工具轮次边界：把用户排队消息作为 user 消息注入历史（含实时落库与转录记录），
/// 下一轮请求即可见。先整批取走（减少持锁时间），再逐条注入；失败仅丢弃该条。
fn injectPendingSends(job: *StreamJob, worker_db: *?db_mod.Db) void {
    const app = job.app;
    var taken: std.ArrayListUnmanaged([]u8) = .{ .items = &.{}, .capacity = 0 };
    defer taken.deinit(app.allocator);
    {
        app.pending_sends_mutex.lockUncancelable(app.io);
        defer app.pending_sends_mutex.unlock(app.io);
        if (app.pending_sends.items.len == 0) return;
        taken.appendSlice(app.allocator, app.pending_sends.items) catch return;
        app.pending_sends.clearRetainingCapacity();
    }

    const arena = job.arena.allocator();
    for (taken.items) |text| {
        defer app.allocator.free(text);
        const owned = arena.dupe(u8, text) catch continue;
        const user_msg = ai.Message{ .role = "user", .content = owned };
        job.transcript.append(arena, .{ .msg = user_msg }) catch continue;
        job.history = extendHistory(arena, job.history, &[_]ai.Message{user_msg}) catch continue;
        // 立即落库（与顺序一致）；失败留给 finalize 的批量兜底
        if (ensureWorkerDb(job, worker_db)) |wdb| {
            persistTranscriptEntry(job, wdb, job.transcript.items.len - 1, job.history.len - 1);
        }
        pushStreamEvent(app, .user_sent, "", "", "", "", false);
    }
}

fn streamWorker(job: *StreamJob) void {
    const app = job.app;
    const arena = job.arena.allocator();
    var client = ai.AI.init(app.allocator, job.io, .{
        .api_key = job.api_key,
        .endpoint = job.endpoint,
        .model = job.model,
        .session_id = job.session_id,
        .behavior = job.behavior,
    });
    client.environ_map = job.environ_map;

    // 实时落库/中途压缩共用一条 worker 连接（主线程连接不跨线程使用）
    var worker_db: ?db_mod.Db = null;
    defer if (worker_db) |*d| d.deinit();

    // 持续循环，直到模型不再返回工具调用（自然结束）、出错或被用户取消
    while (true) {
        var tool_calls = ai.ToolCallAccumulator{ .allocator = arena };
        job.content.clearRetainingCapacity();
        job.reasoning.clearRetainingCapacity();
        job.reasoning_start_ms = 0;
        job.reasoning_end_ms = 0;

        // 工具轮次边界：把用户排队消息注入历史（下一轮请求即可见）
        injectPendingSends(job, &worker_db);

        // 工具循环会迅速堆积上下文：发下一轮前检查并按需压缩
        // （消息已实时落库，整段历史含当前回合都可参与）
        if (job.auto_compact_pct > 0) {
            if (ensureWorkerDb(job, &worker_db)) |wdb| {
                _ = compactJobHistory(job, wdb);
            }
        }

        const result = client.streamMessage(
            job.history,
            &tool_schemas,
            &app.stream_cancel,
            job,
            onStreamDelta,
            &tool_calls,
        );
        job.usage_input += client.usage.input_tokens;
        job.usage_output += client.usage.output_tokens;
        job.usage_cached += client.usage.cached_tokens;
        job.round_usage = client.usage;

        if (result) |_| {} else |err| {
            // 失败/取消：保留已累积的内容与工具调用后退出（同样实时落库）
            if (job.content.items.len > 0 or tool_calls.items.items.len > 0) {
                if (appendAssistantTurn(job, arena, tool_calls.items.items)) |_| {
                    if (ensureWorkerDb(job, &worker_db)) |wdb| {
                        persistTranscriptEntry(job, wdb, job.transcript.items.len - 1, job.history.len - 1);
                    }
                } else |_| {}
            }
            // 取走服务端错误详情（若有）
            if (client.takeErrorBody()) |body| {
                defer app.allocator.free(body);
                job.error_detail = arena.dupe(u8, body) catch "";
            }
            if (err == error.Canceled) {
                app.setStreamStatus(.canceled);
            } else {
                app.stream_error = err;
                app.setStreamStatus(.failed);
            }
            return;
        }

        const has_content = job.content.items.len > 0;
        const has_calls = tool_calls.items.items.len > 0;
        if (has_content or has_calls) {
            if (appendAssistantTurn(job, arena, tool_calls.items.items)) |_| {
                if (ensureWorkerDb(job, &worker_db)) |wdb| {
                    persistTranscriptEntry(job, wdb, job.transcript.items.len - 1, job.history.len - 1);
                }
            } else |_| {}
        }
        if (!has_calls) {
            app.setStreamStatus(.done);
            return;
        }

        // 确保主线程已显示完本轮正文，再进入工具阶段
        waitDrained(app);
        pushStreamEvent(app, .turn_end, "", "", "", "", false);

        for (tool_calls.items.items) |tc| {
            if (app.stream_cancel.load(.acquire)) {
                app.setStreamStatus(.canceled);
                return;
            }
            const args_summary = summarizeToolArgs(arena, tc.arguments) catch "";
            pushStreamEvent(app, .tool_start, tc.name, args_summary, tc.arguments, "", false);

            const exec_result = tools_mod.executeWithEnv(arena, job.io, job.cwd, tc.name, tc.arguments, job.environ_map) catch |e| blk: {
                const msg = std.fmt.allocPrint(arena, "Tool execution failed: {s}", .{@errorName(e)}) catch "Tool execution failed";
                break :blk tools_mod.Result{ .content = @constCast(msg), .is_error = true };
            };

            const result_summary = summarizeToolResult(arena, exec_result) catch "";
            // 块内容：edit → diff 展示文本；bash → 原始输出
            const payload: []const u8 = if (exec_result.display) |d|
                d
            else if (std.mem.eql(u8, tc.name, "bash"))
                exec_result.content
            else
                "";
            pushStreamEvent(app, .tool_end, tc.name, result_summary, tc.arguments, payload, exec_result.is_error);

            // 记录渲染元数据（落库后供重启恢复工具块）
            job.tool_meta.append(arena, .{
                .id = tc.id,
                .name = tc.name,
                .display = if (exec_result.display) |d| d else "",
                .is_error = exec_result.is_error,
            }) catch {};

            // 工具输出可能含非法 UTF-8（如 GBK 文件内容），先清洗再入历史
            const safe_content = sanitizeDup(arena, exec_result.content) catch exec_result.content;
            const tool_msg = ai.Message{
                .role = "tool",
                .content = safe_content,
                .tool_call_id = tc.id,
            };
            job.transcript.append(arena, .{ .msg = tool_msg }) catch break;
            job.history = extendHistory(arena, job.history, &[_]ai.Message{tool_msg}) catch break;
            // 工具结果立即落库：意外退出也能保住已执行的结果
            if (ensureWorkerDb(job, &worker_db)) |wdb| {
                persistTranscriptEntry(job, wdb, job.transcript.items.len - 1, job.history.len - 1);
            }
        }

        waitDrained(app);
    }
}

fn onStreamDelta(ctx: *anyopaque, kind: ai.DeltaKind, delta: []const u8) void {
    const job: *StreamJob = @ptrCast(@alignCast(ctx));
    const app = job.app;
    app.stream_mutex.lockUncancelable(app.io);
    defer app.stream_mutex.unlock(app.io);
    if (kind == .content) {
        const arena = job.arena.allocator();
        job.content.appendSlice(arena, delta) catch {};
        app.stream_buf.appendSlice(app.allocator, delta) catch {};
    } else {
        const arena = job.arena.allocator();
        const now = std.Io.Timestamp.now(job.io, .awake).toMilliseconds();
        if (job.reasoning_start_ms == 0) job.reasoning_start_ms = now;
        job.reasoning_end_ms = now;
        job.reasoning.appendSlice(arena, delta) catch {};
        app.stream_reasoning_buf.appendSlice(app.allocator, delta) catch {};
    }
}

fn drawFrame(state: *AppState, buf: *Buffer) void {
    const area = buf.getArea();

    if (area.width < 30 or area.height < 10) return;

    // 输入光标闪烁：按键后 500ms 内保持实心，之后 1 秒周期闪烁
    const now_ms = std.Io.Timestamp.now(state.io, .awake).toMilliseconds();
    state.input.blink_on = @mod(now_ms - state.blink_anchor_ms, 1000) < 500;

    // 输入内容宽度：边框 + 左侧 1 列缩进
    const input_inner_w = @max(@as(usize, area.width -| 3), 1);
    state.input_wrap_width = input_inner_w;

    var input_lines = state.input.lineCount(input_inner_w);
    if (input_lines < 1) input_lines = 1;
    if (input_lines > 8) input_lines = 8;
    // 上下边框 + 内容行 + 空行 + 底部状态行（模型/提供商）
    var input_box_h: u16 = @intCast(input_lines + 4);
    // 至少给消息区留 1 行 + 帮助栏 1 行 + 输入框上边距 1 行
    if (input_box_h + 3 > area.height) input_box_h = area.height -| 3;

    // 聊天消息区：左边距 2 列，底部与输入框之间留 1 行外边距
    const chat_left_margin: u16 = 2;
    const input_top_margin: u16 = 1;

    const message_area = Rect{
        .x = area.x +| chat_left_margin,
        .y = area.y,
        .width = area.width -| chat_left_margin,
        .height = area.height -| (input_box_h + 1 + input_top_margin), // 帮助栏 + 上边距
    };
    drawMessages(state, message_area, buf);
    state.message_visible_rows = message_area.height;
    state.message_wrap_width = message_area.width;

    const input_area = Rect{
        .x = area.x,
        .y = area.y + area.height -| (input_box_h + 1),
        .width = area.width,
        .height = input_box_h,
    };
    state.input_box_top = input_area.y;
    drawInput(state, input_area, buf);

    // 叠加菜单弹窗
    switch (state.mode) {
        .model_select => drawOverlayMenu(state, area, buf, measureModelMenu(state).total_rows, drawModelSelect),
        .provider_models => drawOverlayMenu(state, area, buf, state.model_select_models.len, drawProviderModels),
        .provider_add => drawOverlayMenu(state, area, buf, 10, drawProviderAdd),
        .provider_confirm => {
            // 提供商列表在下，确认对话框叠在上面
            drawOverlayMenu(state, area, buf, measureModelMenu(state).total_rows, drawModelSelect);
            drawProviderConfirmOverlay(state, area, buf);
        },
        .compact_confirm => {
            // 帮助菜单在下，压缩确认对话框叠在上面
            drawOverlayMenu(state, area, buf, help_commands.len, drawHelpSelect);
            drawCompactConfirmOverlay(state, area, buf);
        },
        .thinking_select => drawOverlayMenu(state, area, buf, thinkingLevelsFor(state.currentModel()).len, drawThinkingSelect),
        .preset_select => drawOverlayMenu(state, area, buf, config_mod.presets.len + 1, drawPresetSelect),
        .session_select => drawOverlayMenu(state, area, buf, state.session_list.len + 1, drawSessionSelect),
        .session_confirm => {
            // 会话列表在下，确认对话框叠在上面
            drawOverlayMenu(state, area, buf, state.session_list.len + 1, drawSessionSelect);
            drawConfirmOverlay(state, area, buf);
        },
        .help_select => drawOverlayMenu(state, area, buf, help_commands.len, drawHelpSelect),
        else => {},
    }

    drawToast(state, area, buf);
    drawHelp(state, area, buf);
}

// 在主界面上叠加一个居中的菜单弹窗（高度随内容自适应）
fn drawOverlayMenu(
    state: *AppState,
    area: Rect,
    buf: *Buffer,
    content_rows: usize,
    comptime content: fn (*AppState, Rect, *Buffer) void,
) void {
    const max_h: u16 = @intCast(@as(u32, area.height) * 75 / 100);

    var w: u16 = @intCast(@as(u32, area.width) * 70 / 100);
    w = @max(w, @min(area.width, 44));

    var h: u16 = @intCast(@min(content_rows + 2, @as(usize, max_h)));
    h = @max(h, @min(area.height, 8));

    const popup = tui.centeredRectFixed(area, w, h);

    // 暗化弹窗以外的区域（保留原色，仅加 dim 修饰）
    dimOutsidePopup(buf, popup);

    // 清空弹窗区域（连同样式一起重置，避免背后高亮底色透出）
    clearArea(buf, popup);
    content(state, popup, buf);

    // 记录弹窗内部可见行数，供按键滚动计算使用
    state.menu_visible_rows = if (popup.height >= 2) popup.height - 2 else 0;
}

// 把区域内的单元格重置为空白（含样式与修饰符），用于叠加层清底
fn clearArea(buf: *Buffer, area: Rect) void {
    var y = area.y;
    while (y < area.y + area.height and y < buf.height) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.width and x < buf.width) : (x += 1) {
            // 先经 setChar 写入空格（正确处理宽字符配对），再整体重置样式
            buf.setChar(x, y, ' ', .{ .fg = .reset, .bg = .reset });
            buf.set(x, y, .{});
        }
    }
}

fn dimOutsidePopup(buf: *Buffer, popup: Rect) void {
    var y: u16 = 0;
    while (y < buf.height) : (y += 1) {
        var x: u16 = 0;
        while (x < buf.width) {
            if (y >= popup.y and y < popup.y + popup.height and
                x >= popup.x and x < popup.x + popup.width)
            {
                x = popup.x + popup.width; // 跳过弹窗区域
                continue;
            }
            if (buf.get(x, y)) |cell| {
                if (!cell.isContinuation()) {
                    cell.modifier = cell.modifier.merge(.DIM);
                }
            }
            x += 1;
        }
    }
}

// 从 pos 处取下一段可视行（按换行符与显示宽度切分，支持中文宽字符）
fn nextVisualLine(content: []const u8, width: usize, pos: *usize) ?[]const u8 {
    if (pos.* >= content.len or width == 0) return null;
    const start = pos.*;
    var col: usize = 0;
    var i = start;
    while (i < content.len) {
        var cp_len: usize = std.unicode.utf8ByteSequenceLength(content[i]) catch 1;
        if (i + cp_len > content.len) cp_len = 1;
        const cp: u21 = if (cp_len == 1)
            content[i]
        else
            std.unicode.utf8Decode(content[i .. i + cp_len]) catch 0xFFFD;

        if (cp == '\n') {
            pos.* = i + 1;
            return content[start..i];
        }
        const w: usize = tui.render.codepointWidth(cp);
        if (col + w > width and i > start) {
            pos.* = i;
            return content[start..i];
        }
        col += w;
        i += cp_len;
    }
    pos.* = content.len;
    return content[start..];
}

fn countVisualLines(content: []const u8, width: usize) usize {
    var pos: usize = 0;
    var count: usize = 0;
    while (nextVisualLine(content, width, &pos) != null) {
        count += 1;
    }
    return count;
}

/// 思考块之后是否还有同一条消息的正文（工具块/正文）。
/// 没有正文时不再留"思考块与正文之间"的空行，避免与消息间隔叠加成两行
fn thoughtHasBody(msg: Message) bool {
    if (msg.tool_block != null) return true;
    return msg.content.len > 0;
}

/// 一条消息在指定宽度下占用的可视行数
fn messageRowCount(msg: Message, width: usize) usize {
    var total: usize = 0;
    // 思考块：折叠头 1 行 +（展开时）空行 + 思考内容 + 与正文之间的空行（仅有正文时）
    if (msg.reasoning != null) {
        total += 1;
        if (msg.reasoning_expanded) {
            total += 1;
            total += countVisualLines(msg.reasoning.?, width -| 2);
        }
        if (thoughtHasBody(msg)) total += 1;
    }

    // 工具块：shell 按宽度折行；diff 每逻辑行一行（不折行）
    if (msg.tool_block) |kind| return total + countBlockRows(msg.content, kind, width);

    if (msg.md) |md| {
        for (md) |*line| {
            total += md_mod.rowCount(line, width);
        }
        return total;
    }
    // 用户消息左侧占用 2 列（竖条 + 空格）
    const wrap_w = if (msg.user) width -| 2 else width;
    return total + countVisualLines(msg.content, wrap_w);
}

/// 思考块头行："▸/▾ Thought: 2.3s"（可点击展开/折叠）
fn drawThoughtHeader(state: *AppState, buf: *Buffer, x: u16, y: u16, msg: Message, msg_idx: usize) void {
    const arrow: []const u8 = if (msg.reasoning_expanded) "⌵ " else "> ";
    const xpos = drawTextAt(buf, x, y, arrow, .{ .fg = .cyan });
    var tbuf: [32]u8 = undefined;
    const text = formatThoughtLabel(&tbuf, thoughtDurationMs(state, msg, msg_idx));
    _ = drawTextAt(buf, xpos, y, text, .{ .fg = .{ .rgb = .{ .r = 110, .g = 160, .b = 220 } } });
}

fn formatThoughtLabel(buf: []u8, ms: i64) []const u8 {
    const clamped = if (ms < 0) 0 else ms;
    const secs = @divTrunc(clamped, 1000);
    const tenth = @divTrunc(@mod(clamped, 1000), 100);
    return std.fmt.bufPrint(buf, "Thought: {d}.{d}s", .{ secs, tenth }) catch "Thought";
}

/// 思考耗时：优先用已定格的耗时，进行中（该消息尚无正文）时按当前时间滚动
fn thoughtDurationMs(state: *AppState, msg: Message, msg_idx: usize) i64 {
    if (msg.reasoning == null) return 0;
    if (msg.reasoning_ms > 0) return msg.reasoning_ms;
    if (msg.reasoning_start_ms == 0) return 0;
    var end = msg.reasoning_end_ms;
    if (msg.content.len == 0 and state.isStreaming() and state.streaming_msg_idx == msg_idx) {
        end = std.Io.Timestamp.now(state.io, .awake).toMilliseconds();
    }
    return if (end > msg.reasoning_start_ms) end - msg.reasoning_start_ms else 0;
}

fn recordThoughtRow(state: *AppState, y: u16, msg_idx: usize) void {
    if (state.thought_row_count >= state.thought_rows.len) return;
    state.thought_rows[state.thought_row_count] = .{ .y = y, .msg = msg_idx };
    state.thought_row_count += 1;
}

fn thoughtRowAt(state: *AppState, y: u16) ?usize {
    for (state.thought_rows[0..state.thought_row_count]) |row| {
        if (row.y == y) return row.msg;
    }
    return null;
}

/// 设置思考块展开状态；keep_view 为真时保持上方内容不动（文档流），
/// 否则仅在用户已上翻时补偿偏移，贴底时保持跟随
fn setThoughtExpanded(state: *AppState, msg_idx: usize, expanded: bool, keep_view: bool) void {
    if (msg_idx >= state.messages.items.len) return;
    const msg = &state.messages.items[msg_idx];
    if (msg.reasoning == null) return;
    if (msg.reasoning_expanded == expanded) return;

    const width = state.message_wrap_width;
    const rows_before = if (width > 0) messageRowCount(msg.*, width) else 0;
    msg.reasoning_expanded = expanded;
    const rows_after = if (width > 0) messageRowCount(msg.*, width) else rows_before;

    if (!keep_view and state.scroll_offset == 0) return;
    if (rows_after > rows_before) {
        state.scroll_offset +|= rows_after - rows_before;
    } else if (rows_before > rows_after) {
        state.scroll_offset -|= rows_before - rows_after;
    }
}

fn toggleThought(state: *AppState, msg_idx: usize) void {
    if (msg_idx >= state.messages.items.len) return;
    const msg = &state.messages.items[msg_idx];
    if (msg.reasoning == null) return;
    setThoughtExpanded(state, msg_idx, !msg.reasoning_expanded, true);
}

fn drawMessages(state: *AppState, area: Rect, buf: *Buffer) void {
    if (area.height == 0 or area.width == 0) return;

    const width: usize = area.width;
    const visible_lines = @as(usize, area.height);

    state.sel_row_count = 0;
    state.thought_row_count = 0;

    // 统计全部可视行数（消息之间各有一个空行）
    var total_lines: usize = 0;
    for (state.messages.items) |msg| {
        total_lines += messageRowCount(msg, width);
    }
    if (state.messages.items.len > 1) total_lines += state.messages.items.len - 1;

    if (total_lines == 0) {
        buf.setString(area.x, area.y, "暂无消息", .{ .fg = .dark_gray });
        return;
    }

    // scroll_offset = 从底部往上滚动的行数（0 = 显示最新内容）
    const max_offset = if (total_lines > visible_lines) total_lines - visible_lines else 0;
    const offset = @min(state.scroll_offset, max_offset);
    state.scroll_offset = offset;
    const start_line = total_lines -| visible_lines -| offset;

    // 从 start_line 开始绘制（同时构建选择映射）
    var current_line: usize = 0;
    var y = area.y;
    outer: for (state.messages.items, 0..) |msg, msg_idx| {
        // 思考块：折叠头（可点击切换）+ 展开时的思考内容
        if (msg.reasoning != null) {
            if (current_line >= start_line) {
                if (y >= area.y + area.height) break :outer;
                drawThoughtHeader(state, buf, area.x, y, msg, msg_idx);
                recordThoughtRow(state, y, msg_idx);
                y += 1;
            }
            current_line += 1;

            if (msg.reasoning_expanded) {
                // 头与思考内容之间空一行
                if (current_line >= start_line) {
                    if (y >= area.y + area.height) break :outer;
                    y += 1;
                }
                current_line += 1;

                var tpos: usize = 0;
                while (nextVisualLine(msg.reasoning.?, width -| 2, &tpos)) |text| {
                    if (current_line >= start_line) {
                        if (y >= area.y + area.height) break :outer;
                        _ = buf.putString(area.x +| 2, y, text, area.width -| 2, .{ .fg = .dark_gray });
                        recordReasoningRow(state, msg_idx, msg.reasoning.?, text, area.x +| 2, y);
                        y += 1;
                    }
                    current_line += 1;
                }
            }

            // 思考块与正文之间空一行（无正文时不留，避免与消息间隔叠成两行）
            if (thoughtHasBody(msg)) {
                if (current_line >= start_line) {
                    if (y >= area.y + area.height) break :outer;
                    y += 1;
                }
                current_line += 1;
            }
        }

        if (msg.tool_block) |block_kind| {
            // 工具块：整块底色。shell 标题/输出自动折行；diff 每行一条（截断）
            var lpos: usize = 0;
            var line_index: usize = 0;
            while (nextBlockLine(msg.content, &lpos)) |text| {
                if (block_kind == .diff) {
                    if (current_line >= start_line) {
                        if (y >= area.y + area.height) break :outer;
                        drawToolBlockRow(state, buf, area, msg_idx, msg.content, text, line_index, block_kind, msg.tool_error, y);
                        y += 1;
                    }
                    current_line += 1;
                } else {
                    var vpos: usize = 0;
                    var vindex: usize = 0;
                    while (true) : (vindex += 1) {
                        const seg_opt = nextVisualLine(text, width, &vpos);
                        const seg: []const u8 = seg_opt orelse "";
                        var more = vpos < text.len;
                        var show_ellipsis = false;
                        // 标题超过上限：最后一行以 … 收尾
                        if (line_index == 0 and vindex + 1 >= shell_header_max_rows and more) {
                            show_ellipsis = true;
                            more = false;
                        }
                        if (current_line >= start_line) {
                            if (y >= area.y + area.height) break :outer;
                            const draw_text: []const u8 = if (show_ellipsis) "…" else seg;
                            drawToolBlockRow(state, buf, area, msg_idx, msg.content, draw_text, line_index, block_kind, msg.tool_error, y);
                            y += 1;
                        }
                        current_line += 1;
                        if (!more) break;
                    }
                }
                line_index += 1;
            }
        } else if (msg.md) |md| {
            for (md) |*line| {
                const rows = md_mod.rowCount(line, width);
                var r: usize = 0;
                while (r < rows) : (r += 1) {
                    if (current_line >= start_line) {
                        if (y >= area.y + area.height) break :outer;
                        md_mod.drawRow(buf, area.x, y, line, width, r, md_mod.default_styles);
                        recordMdRow(state, msg_idx, msg.content, line, width, r, area.x, y);
                        y += 1;
                    }
                    current_line += 1;
                }
            }
        } else {
            const wrap_w = if (msg.user) width -| 2 else width;
            const text_x = if (msg.user) area.x +| 2 else area.x;
            const text_w = if (msg.user) area.width -| 2 else area.width;
            var pos: usize = 0;
            while (nextVisualLine(msg.content, wrap_w, &pos)) |text| {
                if (current_line >= start_line) {
                    if (y >= area.y + area.height) break :outer;
                    if (msg.user) {
                        // 左侧竖条：与输入框边框同色（粉紫）
                        _ = buf.putString(area.x, y, "▌", 1, .{ .fg = .magenta });
                    }
                    _ = buf.putString(text_x, y, text, text_w, msg.style);
                    recordPlainRow(state, msg_idx, msg.content, text, text_x, y);
                    y += 1;
                }
                current_line += 1;
            }
        }

        // 消息之间插入一个空行
        if (msg_idx + 1 < state.messages.items.len) {
            if (current_line >= start_line) {
                if (y >= area.y + area.height) break :outer;
                y += 1;
            }
            current_line += 1;
        }
    }

    // 选中高亮（内容坐标 → 当前帧屏幕位置）
    if (state.sel_active and state.sel_area == .messages) {
        highlightSelection(state, buf);
    }

    // 滚动指示器
    if (total_lines > visible_lines) {
        if (offset + visible_lines < total_lines) {
            buf.setString(area.x + area.width -| 3, area.y, " ▲ ", .{ .fg = .yellow });
        }
        if (offset > 0) {
            buf.setString(area.x + area.width -| 3, area.y + area.height -| 1, " ▼ ", .{ .fg = .yellow });
        }
    }
}

/// 屏幕行 → 该行的内容位置（x 超出片段范围时夹取到最近端点）
fn pointInRow(row: *const SelRow, x: u16) ?SelPoint {
    var first: ?SelPoint = null;
    var first_x: u16 = 0;
    var last: ?SelPoint = null;
    for (row.segs[0..row.seg_count]) |seg| {
        if (seg.off == sel_no_off) continue;
        if (first == null) {
            first = .{ .msg = row.msg, .source = row.source, .off = seg.off };
            first_x = seg.x;
        }
        if (x >= seg.x and x < seg.x +| seg.width) {
            return .{ .msg = row.msg, .source = row.source, .off = seg.off + offsetInSegment(seg, x - seg.x) };
        }
        last = .{ .msg = row.msg, .source = row.source, .off = seg.off + seg.text.len };
    }
    if (first) |f| {
        if (x < first_x) return f;
        return last;
    }
    return null;
}

/// 行映射是否仍指向当前消息缓冲（防御：绘制后内容被重分配/释放的陈旧行）
fn rowSegmentsLive(state: *const AppState, row: *const SelRow) bool {
    if (row.msg >= state.messages.items.len) return false;
    if (row.seg_count == 0) return true;
    const msg = state.messages.items[row.msg];
    const buf: []const u8 = if (row.source == .reasoning)
        (if (msg.reasoning) |r| r else "")
    else
        msg.content;
    if (buf.len == 0) return false;
    const base = @intFromPtr(buf.ptr);
    const end = base + buf.len;
    for (row.segs[0..row.seg_count]) |seg| {
        if (seg.off == sel_no_off) continue;
        const p = @intFromPtr(seg.text.ptr);
        if (p < base or p + seg.text.len > end) return false;
    }
    return true;
}

/// 记录一条 Markdown 渲染行的选择映射。
/// 非内容片段（边框/填充空格）不占槽位，而是折叠进前一个内容片段的宽度，
/// 这样复杂表格行也能完整记录。
fn recordMdRow(state: *AppState, msg_idx: usize, content: []const u8, line: *const md_mod.Line, width: usize, target_row: usize, x0: u16, y: u16) void {
    if (state.sel_row_count >= state.sel_rows.len) return;
    const row = &state.sel_rows[state.sel_row_count];
    row.* = .{ .y = y, .msg = msg_idx, .source = .content, .seg_count = 0 };

    var raw: [64]md_mod.Segment = undefined;
    const n = md_mod.rowSegments(line, width, target_row, &raw);

    const base = @intFromPtr(content.ptr);
    const endp = base + content.len;
    for (raw[0..n]) |seg| {
        const p = @intFromPtr(seg.text.ptr);
        const seg_x: u16 = x0 +| @as(u16, @intCast(@min(seg.x, 0xFFFF)));
        const seg_w: u16 = @intCast(@min(seg.width, 0xFFFF));
        if (p >= base and p + seg.text.len <= endp) {
            if (row.seg_count >= row.segs.len) break;
            row.segs[row.seg_count] = .{
                .text = seg.text,
                .off = p - base,
                .x = seg_x,
                .width = seg_w,
            };
            row.seg_count += 1;
        } else if (row.seg_count > 0) {
            // 条形/填充等非内容片段：并入前一个内容片段
            const prev = &row.segs[row.seg_count - 1];
            const end_x = seg_x +| seg_w;
            if (end_x > prev.x) prev.width = end_x - prev.x;
        }
    }
    state.sel_row_count += 1;
}

/// 记录一条纯文本渲染行的选择映射
fn recordPlainRow(state: *AppState, msg_idx: usize, content: []const u8, text: []const u8, x: u16, y: u16) void {
    if (state.sel_row_count >= state.sel_rows.len) return;
    const row = &state.sel_rows[state.sel_row_count];
    row.* = .{ .y = y, .msg = msg_idx, .source = .content, .seg_count = 1 };

    var entry = SelSegment{
        .text = text,
        .x = x,
        .width = @intCast(@min(tui.render.stringWidth(text), 0xFFFF)),
    };
    const base = @intFromPtr(content.ptr);
    const p = @intFromPtr(text.ptr);
    if (p >= base and p + text.len <= base + content.len) {
        entry.off = p - base;
    }
    row.segs[0] = entry;
    state.sel_row_count += 1;
}

/// 记录一条思考内容渲染行的选择映射（来源为 reasoning）
fn recordReasoningRow(state: *AppState, msg_idx: usize, reasoning: []const u8, text: []const u8, x: u16, y: u16) void {
    if (state.sel_row_count >= state.sel_rows.len) return;
    const row = &state.sel_rows[state.sel_row_count];
    row.* = .{ .y = y, .msg = msg_idx, .source = .reasoning, .seg_count = 1 };

    var entry = SelSegment{
        .text = text,
        .x = x,
        .width = @intCast(@min(tui.render.stringWidth(text), 0xFFFF)),
    };
    const base = @intFromPtr(reasoning.ptr);
    const p = @intFromPtr(text.ptr);
    if (p >= base and p + text.len <= base + reasoning.len) {
        entry.off = p - base;
    }
    row.segs[0] = entry;
    state.sel_row_count += 1;
}

/// 在渲染缓冲上叠加选中高亮（反色）
fn highlightSelection(state: *AppState, buf: *Buffer) void {
    const lo_hi = orderSelPoints(state.sel_anchor, state.sel_current);
    const lo = lo_hi[0];
    const hi = lo_hi[1];

    const lo_pos = selPointPos(lo);
    const hi_pos = selPointPos(hi);

    for (state.sel_rows[0..state.sel_row_count]) |*row| {
        const row_pos: PartPos = .{ .msg = row.msg, .source = row.source };
        if (partLess(row_pos, lo_pos) or partLess(hi_pos, row_pos)) continue;
        const content_len = if (row.msg < state.messages.items.len) blk: {
            const m = state.messages.items[row.msg];
            break :blk if (row.source == .reasoning) (if (m.reasoning) |r| r.len else 0) else m.content.len;
        } else 0;

        const range: [2]usize = if (partEql(lo_pos, hi_pos))
            .{ lo.off, hi.off }
        else if (partEql(row_pos, lo_pos))
            .{ lo.off, content_len }
        else if (partEql(row_pos, hi_pos))
            .{ 0, hi.off }
        else
            .{ 0, content_len };
        if (range[1] <= range[0]) continue;

        for (row.segs[0..row.seg_count]) |seg| {
            if (seg.off == sel_no_off) continue;
            const off = seg.off;
            if (off >= range[1] or off + seg.text.len <= range[0]) continue;

            var x = seg.x;
            var i: usize = 0;
            while (i < seg.text.len) {
                const dec = decodeUtf8At(seg.text, i);
                const w: usize = tui.render.codepointWidth(dec.cp);
                const g = off + i;
                if (g >= range[0] and g < range[1]) {
                    var k: usize = 0;
                    while (k < w) : (k += 1) {
                        if (buf.get(x +| @as(u16, @intCast(@min(k, 0xFFFF))), row.y)) |cell| {
                            cell.modifier = cell.modifier.merge(.REVERSED);
                        }
                    }
                }
                x +|= @intCast(w);
                i += dec.len;
            }
        }
    }
}

const ModelMenuMetrics = struct {
    selected_row: usize = 0,
    total_rows: usize = 0,
};

// 计算 drawModelSelect 的行布局（最近使用 + 提供商列表）
fn measureModelMenu(state: *AppState) ModelMenuMetrics {
    var m: ModelMenuMetrics = .{};
    var row: usize = 0;
    var idx: usize = 0;

    if (state.model_select_recent_count > 0) {
        row += 1; // "最近使用:" 标题
        for (0..state.model_select_recent_count) |_| {
            if (idx == state.model_select_index) m.selected_row = row;
            row += 1;
            idx += 1;
        }
        row += 1; // 空行
    }

    if (state.config.providers.items.len > 0) {
        row += 1; // "提供商:" 标题
        for (state.config.providers.items) |_| {
            if (idx == state.model_select_index) m.selected_row = row;
            row += 1;
            idx += 1;
        }
    }

    // 「+ 添加提供商…」固定末项
    if (idx == state.model_select_index) m.selected_row = row;
    row += 1;

    if (state.config.providers.items.len == 0 and state.model_select_recent_count == 0) {
        row += 1; // 空状态提示
    }

    m.total_rows = row;
    return m;
}

fn menuRowY(inner: Rect, row: usize, view_start: usize) ?u16 {
    if (row < view_start) return null;
    const offset = row - view_start;
    if (offset >= inner.height) return null;
    return inner.y + @as(u16, @intCast(offset));
}

// 在 (x, y) 处绘制一段文本，返回下一段的起始 x 位置
fn drawTextAt(buf: *Buffer, x: u16, y: u16, text: []const u8, style: Style) u16 {
    buf.setString(x, y, text, style);
    const w = tui.render.stringWidth(text);
    return x + @as(u16, @intCast(@min(w, 0xFFFF)));
}

// 右上角临时悬浮通知：小圆角框，2 秒后自动消失（空闲轮询 80ms，足以准时清除）
fn drawToast(state: *AppState, area: Rect, buf: *Buffer) void {
    if (state.toast_len == 0) return;
    const now = std.Io.Timestamp.now(state.io, .awake).toMilliseconds();
    if (now >= state.toast_until_ms) return;

    const text = state.toast[0..state.toast_len];
    const text_w = tui.render.stringWidth(text);
    const max_box_w: u16 = @min(@as(u16, 56), if (area.width > 4) area.width - 4 else 0);
    if (max_box_w < 12 or area.height < 8) return;
    const box_w: u16 = @intCast(@min(text_w + 4, @as(usize, max_box_w)));
    const box = Rect{
        .x = area.x + area.width - box_w - 2,
        .y = area.y + 1,
        .width = box_w,
        .height = 3,
    };
    if (box.x < area.x or box.y + box.height > area.y + area.height) return;

    clearArea(buf, box);
    const blk = Block{
        .borders = Borders.ALL,
        .border_style = .{ .fg = .yellow },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(box, buf);
    const inner = blk.inner(box);
    if (inner.height == 0 or inner.width <= 2) return;
    buf.setStringTruncated(inner.x + 1, inner.y, text, inner.width - 2, .{ .fg = .white });
}

fn drawModelSelect(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 选择模型 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .yellow },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    // 计算滚动位置，保证当前选中项可见
    const metrics = measureModelMenu(state);
    const visible = @as(usize, inner.height);
    var view_start: usize = 0;
    if (metrics.selected_row >= visible) {
        view_start = metrics.selected_row - visible + 1;
    }

    var row: usize = 0;
    var idx: usize = 0;

    // 最近使用的模型
    if (state.model_select_recent_count > 0) {
        if (menuRowY(inner, row, view_start)) |ry| {
            buf.setString(inner.x, ry, "最近使用:", .{ .fg = .yellow });
        }
        row += 1;

        for (0..state.model_select_recent_count) |i| {
            if (menuRowY(inner, row, view_start)) |ry| {
                const entry = state.model_select_recent[i];
                const model_name = entry.name[0..entry.len];
                const is_selected = idx == state.model_select_index;
                const is_current = state.isCurrentProvider(entry.provider) and
                    std.mem.eql(u8, model_name, state.config.current_model);

                var prefix: []const u8 = "  ";
                var style: Style = .{ .fg = .white };
                var sub_bg: Style = .{};
                if (is_selected) {
                    prefix = "> ";
                    style = .{ .fg = .black, .bg = .white };
                    sub_bg = .{ .bg = .white };
                }

                var x = inner.x;
                x = drawTextAt(buf, x, ry, prefix, style);
                x = drawTextAt(buf, x, ry, model_name, style);

                // 所属提供商（灰色）
                if (entry.provider < state.config.providers.items.len) {
                    var pbuf: [160]u8 = undefined;
                    const ptext = std.fmt.bufPrint(&pbuf, " ({s})", .{state.config.providers.items[entry.provider].name}) catch "";
                    if (ptext.len > 0) {
                        var pstyle = sub_bg;
                        pstyle.fg = .dark_gray;
                        x = drawTextAt(buf, x, ry, ptext, pstyle);
                    }
                }

                // （当前）标记（绿色）
                if (is_current) {
                    var cstyle = sub_bg;
                    cstyle.fg = .green;
                    _ = drawTextAt(buf, x, ry, " (当前)", cstyle);
                }
            }
            row += 1;
            idx += 1;
        }
        row += 1; // 空行
    }

    // 提供商列表
    if (state.config.providers.items.len > 0) {
        if (menuRowY(inner, row, view_start)) |ry| {
            buf.setString(inner.x, ry, "提供商:", .{ .fg = .yellow });
        }
        row += 1;

        for (state.config.providers.items, 0..) |p, pi| {
            if (menuRowY(inner, row, view_start)) |ry| {
                const is_selected = idx == state.model_select_index;
                const is_current = state.isCurrentProvider(pi);

                var prefix: []const u8 = "  ";
                var style: Style = .{ .fg = .white };
                var sub_bg: Style = .{};
                if (is_selected) {
                    prefix = "> ";
                    style = .{ .fg = .black, .bg = .white };
                    sub_bg = .{ .bg = .white };
                }

                var x = inner.x;
                x = drawTextAt(buf, x, ry, prefix, style);
                x = drawTextAt(buf, x, ry, p.name, style);

                // 预设名（灰色）：openai / opencode-go / 自定义
                if (p.preset.len > 0) {
                    if (config_mod.findPreset(p.preset)) |pr| {
                        var dstyle = sub_bg;
                        dstyle.fg = .dark_gray;
                        x = drawTextAt(buf, x, ry, " · ", dstyle);
                        x = drawTextAt(buf, x, ry, pr.display, dstyle);
                    }
                }

                // 缓存/会话亲和方言徽标
                const beh = config_mod.behavior(&p);
                const aff_tag: ?[]const u8 = switch (beh.affinity) {
                    .none => null,
                    .opencode => "zen",
                    .openai => "cache",
                    .openrouter => "or",
                    .fireworks => "affinity",
                };
                if (beh.cache_key or aff_tag != null) {
                    var sb: [64]u8 = undefined;
                    const tag = std.fmt.bufPrint(&sb, " [{s}{s}{s}]", .{
                        if (beh.cache_key) "cache" else "",
                        if (beh.cache_key and aff_tag != null) "+" else "",
                        aff_tag orelse "",
                    }) catch "";
                    if (tag.len > 0) {
                        var gstyle = sub_bg;
                        gstyle.fg = .dark_gray;
                        x = drawTextAt(buf, x, ry, tag, gstyle);
                    }
                }

                // env ✓ / env ✗（key 留空且配置了环境变量名时）
                const env_name = p.effectiveApiKeyEnv();
                if (p.api_key.len == 0 and env_name.len > 0) {
                    const present = if (state.environ_map) |env| env.get(env_name) != null else false;
                    var estyle = sub_bg;
                    estyle.fg = if (present) .green else .dark_gray;
                    x = drawTextAt(buf, x, ry, if (present) " [env ✓]" else " [env ✗]", estyle);
                }

                // （当前）标记（绿色）
                if (is_current) {
                    var cstyle = sub_bg;
                    cstyle.fg = .green;
                    _ = drawTextAt(buf, x, ry, " (当前)", cstyle);
                }
            }
            row += 1;
            idx += 1;
        }
    }

    // 「+ 添加提供商…」
    if (menuRowY(inner, row, view_start)) |ry| {
        const is_selected = idx == state.model_select_index;
        var prefix: []const u8 = "  ";
        var style: Style = .{ .fg = .dark_gray };
        if (is_selected) {
            prefix = "> ";
            style = .{ .fg = .black, .bg = .white };
        }
        var x = inner.x;
        x = drawTextAt(buf, x, ry, prefix, style);
        _ = drawTextAt(buf, x, ry, "+ 添加提供商…", style);
    }
    row += 1;

    if (state.config.providers.items.len == 0 and state.model_select_recent_count == 0) {
        if (menuRowY(inner, row, view_start)) |ry| {
            buf.setString(inner.x, ry, "暂无提供商，选择上方项或按 Ctrl+A", .{ .fg = .dark_gray });
        }
    }
}

/// 删除提供商后修正最近模型引用：移除指向该项的条目，后续下标整体前移
fn pruneRecentProviderRefs(recent: []RecentEntry, count: *usize, removed_idx: usize) void {
    var i: usize = 0;
    while (i < count.*) {
        const e = recent[i];
        if (e.provider == removed_idx) {
            var j = i;
            while (j + 1 < count.*) : (j += 1) {
                recent[j] = recent[j + 1];
            }
            count.* -= 1;
        } else {
            if (e.provider > removed_idx) recent[i].provider = e.provider - 1;
            i += 1;
        }
    }
}

fn drawPresetSelect(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 添加提供商 - 选择预设 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .cyan },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    const visible = @as(usize, inner.height);
    var view_start: usize = 0;
    if (state.preset_select_index >= visible) {
        view_start = state.preset_select_index - visible + 1;
    }

    var row: usize = 0;
    for (config_mod.presets, 0..) |pr, i| {
        if (menuRowY(inner, row, view_start)) |ry| {
            const is_selected = i == state.preset_select_index;
            var prefix: []const u8 = "  ";
            var style: Style = .{ .fg = .white };
            var sub_bg: Style = .{};
            if (is_selected) {
                prefix = "> ";
                style = .{ .fg = .black, .bg = .white };
                sub_bg = .{ .bg = .white };
            }
            var x = inner.x;
            x = drawTextAt(buf, x, ry, prefix, style);
            x = drawTextAt(buf, x, ry, pr.display, style);

            var e_buf: [96]u8 = undefined;
            const env_text = if (pr.api_key_env.len > 0)
                std.fmt.bufPrint(&e_buf, " [{s}]", .{pr.api_key_env}) catch ""
            else
                "";
            if (env_text.len > 0) {
                var estyle = sub_bg;
                const present = if (state.environ_map) |env| env.get(pr.api_key_env) != null else false;
                estyle.fg = if (present) .green else .dark_gray;
                x = drawTextAt(buf, x, ry, env_text, estyle);
            }

            var u_buf: [160]u8 = undefined;
            const url_text = std.fmt.bufPrint(&u_buf, "  {s}", .{pr.endpoint}) catch "";
            var ustyle = sub_bg;
            ustyle.fg = .dark_gray;
            _ = drawTextAt(buf, x, ry, url_text, ustyle);
        }
        row += 1;
    }

    // 末项：自定义
    if (menuRowY(inner, row, view_start)) |ry| {
        const is_selected = state.preset_select_index == config_mod.presets.len;
        var prefix: []const u8 = "  ";
        var style: Style = .{ .fg = .dark_gray };
        if (is_selected) {
            prefix = "> ";
            style = .{ .fg = .black, .bg = .white };
        }
        var x = inner.x;
        x = drawTextAt(buf, x, ry, prefix, style);
        _ = drawTextAt(buf, x, ry, "自定义… (手动填写全部字段)", style);
    }
}

fn drawThinkingSelect(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 选择思考强度 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .yellow },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    const levels = thinkingLevelsFor(state.currentModel());
    var y = inner.y;
    for (levels, 0..) |lv, i| {
        if (y >= inner.y + inner.height) break;
        const is_selected = i == state.thinking_select_index;
        const is_current = std.mem.eql(u8, lv, state.config.thinking);
        var prefix: []const u8 = "  ";
        var style: Style = .{ .fg = .white };
        var sub_bg: Style = .{};
        if (is_selected) {
            prefix = "> ";
            style = .{ .fg = .black, .bg = .white };
            sub_bg = .{ .bg = .white };
        }
        var x = inner.x;
        x = drawTextAt(buf, x, y, prefix, style);
        x = drawTextAt(buf, x, y, lv, style);
        if (is_current) {
            var cstyle = sub_bg;
            cstyle.fg = .green;
            _ = drawTextAt(buf, x, y, " (当前)", cstyle);
        }
        y += 1;
    }
}

fn drawProviderModels(state: *AppState, area: Rect, buf: *Buffer) void {
    var title_buf: [256]u8 = undefined;
    const provider_name = if (state.model_select_provider < state.config.providers.items.len)
        state.config.providers.items[state.model_select_provider].name
    else
        "?";
    const title = std.fmt.bufPrint(&title_buf, " 选择模型 - {s} ", .{provider_name}) catch " 选择模型 ";

    const blk = Block{
        .title = title,
        .borders = Borders.ALL,
        .border_style = .{ .fg = .yellow },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    const visible = @as(usize, inner.height);
    const total = state.model_select_models.len;

    // 使用持久化视口并做边界钳制
    var view_start = state.model_view_start;
    const max_start = if (total > visible) total - visible else 0;
    if (view_start > max_start) view_start = max_start;

    var y = inner.y;
    for (state.model_select_models, 0..) |m, i| {
        if (i < view_start) continue;
        if (y >= inner.y + inner.height) break;
        if (m.id.len == 0) continue;

        const is_selected = i == state.model_select_index;
        const is_current = state.isCurrentProvider(state.model_select_provider) and
            std.mem.eql(u8, m.id, state.config.current_model);

        var prefix: []const u8 = "  ";
        var style: Style = .{ .fg = .white };
        var sub_bg: Style = .{};
        if (is_selected) {
            prefix = "> ";
            style = .{ .fg = .black, .bg = .white };
            sub_bg = .{ .bg = .white };
        }

        var x = inner.x;
        x = drawTextAt(buf, x, y, prefix, style);
        x = drawTextAt(buf, x, y, m.id, style);

        // （当前）标记（绿色）
        if (is_current) {
            var cstyle = sub_bg;
            cstyle.fg = .green;
            _ = drawTextAt(buf, x, y, " (当前)", cstyle);
        }
        y += 1;
    }
}

fn drawSessionSelect(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 选择会话 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .cyan },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    const total = state.session_list.len + 1; // 第 0 项为"新建会话"
    const visible = @as(usize, inner.height);
    var row_start = state.session_view_start;
    const max_start = if (total > visible) total - visible else 0;
    if (row_start > max_start) row_start = max_start;

    const now = std.Io.Timestamp.now(state.io, .real).toSeconds();

    var y = inner.y;
    var i: usize = row_start;
    while (i < total and y < inner.y + inner.height) : (i += 1) {
        const is_selected = i == state.session_select_index;
        var prefix: []const u8 = "  ";
        var style: Style = .{ .fg = .white };
        var sub_bg: Style = .{};
        if (is_selected) {
            prefix = "> ";
            style = .{ .fg = .black, .bg = .white };
            sub_bg = .{ .bg = .white };
        }

        if (i == 0) {
            var x = inner.x;
            x = drawTextAt(buf, x, y, prefix, style);
            _ = drawTextAt(buf, x, y, "＋ 新建会话", style);
        } else {
            const s = state.session_list[i - 1];
            const title = if (s.title.len > 0) s.title else "(未命名)";
            var tbuf: [32]u8 = undefined;
            const rel = formatRelativeTime(&tbuf, now, s.last_active_at);

            var line_buf: [512]u8 = undefined;
            const text = std.fmt.bufPrint(&line_buf, "{s}{s}  ·  {d} 条  ·  {s}", .{ prefix, title, s.msg_count, rel }) catch prefix;
            const x = drawTextAt(buf, inner.x, y, text, style);

            if (s.id == state.session_id) {
                var cstyle = sub_bg;
                cstyle.fg = .green;
                _ = drawTextAt(buf, x, y, " (当前)", cstyle);
            }
        }
        y += 1;
    }
}

fn drawHelpSelect(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 选择操作 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .yellow },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    var y = inner.y;
    for (help_commands, 0..) |cmd, i| {
        if (y >= inner.y + inner.height) break;
        const is_selected = i == state.help_select_index;

        var prefix: []const u8 = "  ";
        var style: Style = .{ .fg = .white };
        var sub_bg: Style = .{};
        if (is_selected) {
            prefix = "> ";
            style = .{ .fg = .black, .bg = .white };
            sub_bg = .{ .bg = .white };
        }

        var name_buf: [20]u8 = undefined;
        const name_padded = std.fmt.bufPrint(&name_buf, "{s:<12}", .{cmd.name}) catch cmd.name;

        var x = inner.x;
        x = drawTextAt(buf, x, y, prefix, style);
        x = drawTextAt(buf, x, y, name_padded, style);

        var dstyle = sub_bg;
        dstyle.fg = if (is_selected) .black else .dark_gray;
        _ = drawTextAt(buf, x, y, cmd.desc, dstyle);
        y += 1;
    }
}

fn drawConfirmOverlay(state: *AppState, area: Rect, buf: *Buffer) void {
    var w: u16 = @intCast(@as(u32, area.width) * 50 / 100);
    w = @min(@max(w, 40), 64);
    var h: u16 = 6;
    if (h > area.height) h = area.height;
    const popup = tui.centeredRectFixed(area, w, h);

    dimOutsidePopup(buf, popup);
    clearArea(buf, popup);
    drawConfirmDialog(state, popup, buf);
}

fn drawConfirmDialog(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 确认删除 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .red },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    var y = inner.y;

    // 第一行：问题
    if (state.confirm_stage == 1) {
        var qb: [96]u8 = undefined;
        const q = std.fmt.bufPrint(&qb, "是否要删除会话 #{d}？", .{state.confirm_session_id}) catch "是否要删除？";
        buf.setString(inner.x, y, q, .{ .fg = .white });
    } else {
        buf.setString(inner.x, y, "真的要删除吗？", .{ .fg = .red, .modifier = .{ .bold = true } });
    }
    y += 1;

    // 第二行：标题 / 警告
    if (inner.height > 1) {
        if (state.confirm_stage == 1) {
            var tb: [160]u8 = undefined;
            const title = if (state.confirm_title_len > 0) state.confirm_title[0..state.confirm_title_len] else "(未命名)";
            const t = std.fmt.bufPrint(&tb, "「{s}」", .{title}) catch "";
            if (t.len > 0) buf.setString(inner.x, y, t, .{ .fg = .dark_gray });
        } else {
            buf.setString(inner.x, y, "删除后无法恢复，消息将一并删除", .{ .fg = .dark_gray });
        }
    }
    y += 2;

    // 按钮行：居中 [ 否 ]  [ 是 ]
    if (y >= inner.y + inner.height) return;
    const no_text = "[ 否 ]";
    const yes_text = "[ 是 ]";
    const no_w = tui.render.stringWidth(no_text);
    const gap: usize = 4;
    const yes_w = tui.render.stringWidth(yes_text);
    const total_w: u16 = @intCast(no_w + gap + yes_w);
    var x = inner.x + (inner.width -| total_w) / 2;

    const no_style: Style = if (!state.confirm_yes)
        .{ .fg = .black, .bg = .white, .modifier = .{ .bold = true } }
    else
        .{ .fg = .white };
    const yes_style: Style = if (state.confirm_yes)
        .{ .fg = .black, .bg = .white, .modifier = .{ .bold = true } }
    else
        .{ .fg = .white };

    x = drawTextAt(buf, x, y, no_text, no_style);
    _ = drawTextAt(buf, x + @as(u16, @intCast(gap)), y, yes_text, yes_style);
}

fn drawProviderConfirmOverlay(state: *AppState, area: Rect, buf: *Buffer) void {
    var w: u16 = @intCast(@as(u32, area.width) * 50 / 100);
    w = @min(@max(w, 40), 64);
    var h: u16 = 6;
    if (h > area.height) h = area.height;
    const popup = tui.centeredRectFixed(area, w, h);

    dimOutsidePopup(buf, popup);
    clearArea(buf, popup);
    drawProviderConfirmDialog(state, popup, buf);
}

fn drawProviderConfirmDialog(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 确认删除提供商 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .red },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    const target = if (state.provider_confirm_index) |idx|
        (if (idx < state.config.providers.items.len) state.config.providers.items[idx] else null)
    else
        null;

    var y = inner.y;

    // 第一行：问题
    if (state.confirm_stage == 1) {
        var qb: [160]u8 = undefined;
        const name = if (target) |p| p.name else "?";
        const q = std.fmt.bufPrint(&qb, "是否要删除提供商「{s}」？", .{name}) catch "是否要删除提供商？";
        buf.setString(inner.x, y, q, .{ .fg = .white });
    } else {
        buf.setString(inner.x, y, "真的要删除吗？", .{ .fg = .red, .modifier = .{ .bold = true } });
    }
    y += 1;

    // 第二行：地址 / 警告
    if (inner.height > 1) {
        if (state.confirm_stage == 1) {
            if (target) |p| {
                var tb: [200]u8 = undefined;
                const t = std.fmt.bufPrint(&tb, "{s}", .{p.endpoint}) catch "";
                if (t.len > 0) buf.setString(inner.x, y, t, .{ .fg = .dark_gray });
            }
        } else {
            buf.setString(inner.x, y, "删除后需重新填写地址与密钥", .{ .fg = .dark_gray });
        }
    }
    y += 2;

    // 按钮行：居中 [ 否 ]  [ 是 ]
    if (y >= inner.y + inner.height) return;
    const no_text = "[ 否 ]";
    const yes_text = "[ 是 ]";
    const no_w = tui.render.stringWidth(no_text);
    const gap: usize = 4;
    const yes_w = tui.render.stringWidth(yes_text);
    const total_w: u16 = @intCast(no_w + gap + yes_w);
    var x = inner.x + (inner.width -| total_w) / 2;

    const no_style: Style = if (!state.confirm_yes)
        .{ .fg = .black, .bg = .white, .modifier = .{ .bold = true } }
    else
        .{ .fg = .white };
    const yes_style: Style = if (state.confirm_yes)
        .{ .fg = .black, .bg = .white, .modifier = .{ .bold = true } }
    else
        .{ .fg = .white };

    x = drawTextAt(buf, x, y, no_text, no_style);
    _ = drawTextAt(buf, x + @as(u16, @intCast(gap)), y, yes_text, yes_style);
}

fn drawCompactConfirmOverlay(state: *AppState, area: Rect, buf: *Buffer) void {
    var w: u16 = @intCast(@as(u32, area.width) * 50 / 100);
    w = @min(@max(w, 40), 64);
    var h: u16 = 6;
    if (h > area.height) h = area.height;
    const popup = tui.centeredRectFixed(area, w, h);

    dimOutsidePopup(buf, popup);
    clearArea(buf, popup);
    drawCompactConfirmDialog(state, popup, buf);
}

fn drawCompactConfirmDialog(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 确认压缩上下文 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .yellow },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    var y = inner.y;
    if (state.confirm_stage == 1) {
        buf.setString(inner.x, y, "是否要压缩当前会话的上下文？", .{ .fg = .white });
    } else {
        buf.setString(inner.x, y, "真的要压缩吗？", .{ .fg = .red, .modifier = .{ .bold = true } });
    }
    y += 1;

    if (inner.height > 1) {
        if (state.confirm_stage == 1) {
            var nb: [24]u8 = undefined;
            var tb: [200]u8 = undefined;
            const t = std.fmt.bufPrint(&tb, "将把较早消息交给模型生成摘要（当前约 {s} tok）", .{
                formatCount(&nb, @intCast(state.estimateRequestTokens())),
            }) catch "将把较早消息交给模型生成摘要";
            buf.setString(inner.x, y, t, .{ .fg = .dark_gray });
        } else {
            buf.setString(inner.x, y, "较早消息将只保留摘要；原文仍可回看（会产生一次模型请求）", .{ .fg = .dark_gray });
        }
    }
    y += 2;

    // 按钮行：居中 [ 否 ]  [ 是 ]
    if (y >= inner.y + inner.height) return;
    const no_text = "[ 否 ]";
    const yes_text = "[ 是 ]";
    const no_w = tui.render.stringWidth(no_text);
    const gap: usize = 4;
    const yes_w = tui.render.stringWidth(yes_text);
    const total_w: u16 = @intCast(no_w + gap + yes_w);
    var x = inner.x + (inner.width -| total_w) / 2;

    const no_style: Style = if (!state.confirm_yes)
        .{ .fg = .black, .bg = .white, .modifier = .{ .bold = true } }
    else
        .{ .fg = .white };
    const yes_style: Style = if (state.confirm_yes)
        .{ .fg = .black, .bg = .white, .modifier = .{ .bold = true } }
    else
        .{ .fg = .white };

    x = drawTextAt(buf, x, y, no_text, no_style);
    _ = drawTextAt(buf, x + @as(u16, @intCast(gap)), y, yes_text, yes_style);
}

fn formatRelativeTime(buf: []u8, now: i64, ts: i64) []const u8 {
    var diff = now - ts;
    if (diff < 0) diff = 0;
    if (diff < 60) return std.fmt.bufPrint(buf, "刚刚", .{}) catch "";
    if (diff < 3600) return std.fmt.bufPrint(buf, "{d} 分钟前", .{@divTrunc(diff, 60)}) catch "";
    if (diff < 86400) return std.fmt.bufPrint(buf, "{d} 小时前", .{@divTrunc(diff, 3600)}) catch "";
    if (diff < 86400 * 30) return std.fmt.bufPrint(buf, "{d} 天前", .{@divTrunc(diff, 86400)}) catch "";
    if (diff < 86400 * 365) return std.fmt.bufPrint(buf, "{d} 个月前", .{@divTrunc(diff, 86400 * 30)}) catch "";
    return std.fmt.bufPrint(buf, "{d} 年前", .{@divTrunc(diff, 86400 * 365)}) catch "";
}

fn drawProviderAdd(state: *AppState, area: Rect, buf: *Buffer) void {
    const title = if (state.provider_edit_index != null) " 编辑提供商 " else " 添加提供商 ";
    const blk = Block{
        .title = title,
        .borders = Borders.ALL,
        .border_style = .{ .fg = .cyan },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height < 10 or inner.width < 24) return;

    var y = inner.y + 1;
    if (state.providerFormLocked()) {
        // 预设字段：名称/地址只读展示
        drawFormStatic(buf, inner, y, "名称", state.provider_form_name.value());
        y += 2;
        drawFormStatic(buf, inner, y, "地址", state.provider_form_url.value());
        y += 2;
        drawFormField(buf, inner, y, "密钥", &state.provider_form_key, state.provider_form_field == 2);
        y += 2;
        drawFormField(buf, inner, y, "环境变量", &state.provider_form_key_env, state.provider_form_field == 3);

        if (y + 2 < inner.y + inner.height) {
            buf.setString(inner.x, y + 2, "名称/地址来自预设不可修改；密钥留空时回退读环境变量 (Ctrl+U 清空字段)", .{ .fg = .dark_gray });
        }
        return;
    }

    drawFormField(buf, inner, y, "名称", &state.provider_form_name, state.provider_form_field == 0);
    y += 2;
    drawFormField(buf, inner, y, "地址", &state.provider_form_url, state.provider_form_field == 1);
    y += 2;
    drawFormField(buf, inner, y, "密钥", &state.provider_form_key, state.provider_form_field == 2);
    y += 2;
    drawFormField(buf, inner, y, "环境变量", &state.provider_form_key_env, state.provider_form_field == 3);

    if (y + 2 < inner.y + inner.height) {
        buf.setString(inner.x, y + 2, "名称与地址必填；密钥留空时回退读环境变量 (Ctrl+U 清空字段)", .{ .fg = .dark_gray });
    }
}

/// 只读字段：标签 + 值（无输入框，浅色展示）
fn drawFormStatic(buf: *Buffer, inner: Rect, y: u16, label: []const u8, value: []const u8) void {
    var lbuf: [24]u8 = undefined;
    const label_text = std.fmt.bufPrint(&lbuf, "{s}: ", .{label}) catch label;
    buf.setString(inner.x, y, label_text, .{ .fg = .dark_gray });

    const off = tui.render.stringWidth(label_text);
    const x = inner.x +| @as(u16, @intCast(@min(off, 0xFFFF)));
    if (x >= inner.x + inner.width) return;
    buf.setStringTruncated(x, y, value, inner.x + inner.width - x, .{ .fg = .dark_gray });
}

fn drawFormField(buf: *Buffer, inner: Rect, y: u16, label: []const u8, input: *TextInput(256), focused: bool) void {
    const label_style: Style = if (focused)
        .{ .fg = .cyan, .modifier = .{ .bold = true } }
    else
        .{ .fg = .dark_gray };

    var lbuf: [24]u8 = undefined;
    const label_text = std.fmt.bufPrint(&lbuf, "{s}: ", .{label}) catch label;
    buf.setString(inner.x, y, label_text, label_style);

    // 用显示宽度而非字节数计算偏移（中文标签宽度 ≠ 字节数）
    const off = tui.render.stringWidth(label_text);
    const x = inner.x +| @as(u16, @intCast(@min(off, 0xFFFF)));
    if (x >= inner.x + inner.width) return;
    input.render(.{
        .x = x,
        .y = y,
        .width = inner.x + inner.width - x,
        .height = 1,
    }, buf);
}

fn drawInput(state: *AppState, area: Rect, buf: *Buffer) void {
    const blk = Block{
        .title = " 输入 ",
        .borders = Borders.ALL,
        .border_style = .{ .fg = .magenta },
        .title_style = .{ .fg = .white, .modifier = .{ .bold = true } },
        .border_symbols = BorderSymbols.rounded(),
    };
    blk.render(area, buf);

    const inner = blk.inner(area);
    if (inner.height == 0 or inner.width == 0) return;

    state.input_sel_row_count = 0;
    state.input_content_rows = 0;

    // 内容区：左缩进 1 列对齐状态栏；底部预留 1 空行 + 1 状态行
    if (inner.height > 2 and inner.width > 1) {
        const content = Rect{
            .x = inner.x + 1,
            .y = inner.y,
            .width = inner.width - 1,
            .height = inner.height - 2,
        };
        state.input_content_rows = content.height;
        // 选区交给 TextArea 渲染（光标叠加在选中字符上时使用灰底光标块）
        state.input.sel_range = if (state.sel_active and state.sel_area == .input)
            state.inputSelectionRange()
        else
            null;
        state.input.applyViewport(content.width, content.height);
        state.input.render(content, buf);

        // 构建输入框选择映射（与 render 的视口保持一致）
        const view_start = state.input.view_start;
        var row_index = view_start;
        var y = content.y;
        while (y < content.y + content.height and state.input_sel_row_count < state.input_sel_rows.len) : (row_index += 1) {
            const range = state.input.rowByteRange(content.width, row_index) orelse break;
            state.input_sel_rows[state.input_sel_row_count] = .{
                .y = y,
                .start = range[0],
                .end = range[1],
                .x = content.x,
            };
            state.input_sel_row_count += 1;
            y += 1;
        }

        // 输入框选区高亮由 TextArea.render 处理（见 sel_range）
    }

    // 状态栏：模型 · 提供商（淡灰色）
    drawInputStatus(state, .{
        .x = inner.x,
        .y = inner.y + inner.height - 1,
        .width = inner.width,
        .height = 1,
    }, buf);
}

fn drawInputStatus(state: *AppState, area: Rect, buf: *Buffer) void {
    if (area.height == 0 or area.width == 0) return;

    var x = area.x;
    const end_x = area.x +| area.width;

    const model = state.currentModel();
    var provider_name: []const u8 = "";
    if (state.currentProvider()) |p| provider_name = p.name;

    if (model.len > 0) {
        // 最左：上下文占用（已用/窗口 + 百分比，按压力着色）
        const used_tokens = state.context_usage.input_tokens + state.context_usage.output_tokens;
        if (used_tokens > 0) {
            const ctx = modelContextWindow(model);
            const pct = contextUsagePercent(used_tokens, ctx);
            var b0: [24]u8 = undefined;
            var b1: [24]u8 = undefined;
            var sb: [96]u8 = undefined;
            const size_text = std.fmt.bufPrint(&sb, " {s}{s}/{s} ", .{
                if (state.usage_estimated) "~" else "",
                formatCount(&b0, used_tokens),
                formatCount(&b1, ctx),
            }) catch "";
            if (size_text.len > 0) {
                x = drawStatusSegment(buf, x, end_x, area.y, size_text, .{ .fg = .dark_gray });
            }
            var pb: [16]u8 = undefined;
            const pct_text = std.fmt.bufPrint(&pb, "{d}%", .{pct}) catch "";
            if (pct_text.len > 0) {
                const pct_color: tui.style.Color = if (pct >= 80) .red else if (pct >= 50) .yellow else .green;
                x = drawStatusSegment(buf, x, end_x, area.y, pct_text, .{ .fg = pct_color });
            }
            x = drawStatusSegment(buf, x, end_x, area.y, " ·", .{ .fg = .dark_gray });
        }

        x = drawStatusSegment(buf, x, end_x, area.y, " ", .{ .fg = .dark_gray });
        x = drawStatusSegment(buf, x, end_x, area.y, model, .{ .fg = .cyan });
        if (provider_name.len > 0) {
            x = drawStatusSegment(buf, x, end_x, area.y, " · ", .{ .fg = .dark_gray });
            x = drawStatusSegment(buf, x, end_x, area.y, provider_name, .{ .fg = .dark_gray });
        }
        if (state.config.thinking.len > 0) {
            var tb: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&tb, " · think:{s}", .{state.config.thinking}) catch "";
            if (text.len > 0) {
                x = drawStatusSegment(buf, x, end_x, area.y, text, .{ .fg = .yellow });
            }
        }
        if (state.context_usage.cached_tokens > 0 and state.context_usage.input_tokens > 0) {
            var cb0: [24]u8 = undefined;
            var cb1: [24]u8 = undefined;
            var sb: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&sb, " · 缓存 {s}/{s} ", .{
                formatCount(&cb0, state.context_usage.cached_tokens),
                formatCount(&cb1, state.context_usage.input_tokens),
            }) catch "";
            if (text.len > 0) {
                x = drawStatusSegment(buf, x, end_x, area.y, text, .{ .fg = .dark_gray });
            }
            // 命中率：高命中绿色、中等黄色、低命中红色（与上下文占用同风格）
            const hit = cacheHitPercent(state.context_usage.cached_tokens, state.context_usage.input_tokens);
            var hb: [16]u8 = undefined;
            const hit_text = std.fmt.bufPrint(&hb, "{d}%", .{hit}) catch "";
            if (hit_text.len > 0) {
                const hit_color: tui.style.Color = if (hit >= 80) .green else if (hit >= 50) .yellow else .red;
                _ = drawStatusSegment(buf, x, end_x, area.y, hit_text, .{ .fg = hit_color });
            }
        }
    } else if (provider_name.len > 0) {
        var sb: [192]u8 = undefined;
        const text = std.fmt.bufPrint(&sb, " 未选择模型 · {s}", .{provider_name}) catch " 未选择模型";
        _ = drawStatusSegment(buf, x, end_x, area.y, text, .{ .fg = .dark_gray });
    } else {
        _ = drawStatusSegment(buf, x, end_x, area.y, " 未选择模型", .{ .fg = .dark_gray });
    }
}

fn drawStatusSegment(buf: *Buffer, x: u16, end_x: u16, y: u16, text: []const u8, style: Style) u16 {
    if (x >= end_x or text.len == 0) return x;
    buf.setStringTruncated(x, y, text, end_x - x, style);
    const w = tui.render.stringWidth(text);
    return x +| @as(u16, @intCast(@min(w, 0xFFFF)));
}

fn drawHelp(state: *AppState, area: Rect, buf: *Buffer) void {
    const help = switch (state.mode) {
        .model_select => " [Ctrl+A] 添加  [Ctrl+E] 编辑  [Del] 删除  [Esc] 取消 ",
        .provider_models => " [↑↓] 选择模型  [Enter] 确认  [Ctrl+E] 编辑提供商  [Esc] 返回 ",
        .preset_select => " [↑↓] 选择预设  [Enter] 下一步  [Esc] 返回 ",
        .provider_confirm => " [←→] 切换选项  [Enter] 确认  [Esc] 取消 ",
        .compact_confirm => " [←→] 切换选项  [Enter] 确认  [Esc] 取消 ",
        .thinking_select => " [↑↓] 选择思考强度  [Enter] 确认  [Esc] 返回 ",
        .provider_add => " [Tab] 切换字段  [Enter] 下一项/保存  [Esc] 取消 ",
        .session_select => " [↑↓] 选择会话  [Enter] 加载/新建  [Del] 删除  [Esc] 取消 ",
        .session_confirm => " [←→] 切换选项  [Enter] 确认  [Esc] 取消 ",
        .help_select => " [↑↓] 选择指令  [Enter] 执行  [Esc] 取消 ",
        else => " [Enter] 发送  [Ctrl+J] 换行  [PgUp/PgDn] 滚动  [Esc] 菜单 ",
    };
    const y = area.y + area.height - 1;
    const help_width = tui.render.stringWidth(help);
    const x = area.x + (area.width -| @as(u16, @intCast(help_width))) / 2;
    buf.setString(x, y, help, .{ .fg = .dark_gray });
}

test {
    // 让 `zig build test` 收集这些文件中的测试
    _ = @import("ai.zig");
    _ = @import("db.zig");
    _ = @import("markdown.zig");
    _ = @import("regex.zig");
    _ = @import("textarea.zig");
    _ = @import("tools.zig");
    _ = @import("context.zig");
    _ = @import("cli_args.zig");
}

test "历史消息会清洗非法 UTF-8（避免 JSON 退化为字节数组）" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
    }

    const bad = [_]u8{ 'h', 'i', 0xB7, 'x' }; // 0xB7：GBK 常见字节，非法 UTF-8
    state.appendHistory("user", &bad);

    try std.testing.expectEqual(@as(usize, 1), state.history.items.len);
    const content = state.history.items[0].content;
    try std.testing.expect(std.unicode.utf8ValidateSlice(content));
    try std.testing.expectEqualStrings("hi\u{FFFD}x", content);

    // 构建请求体时 content 必须是 JSON 字符串而非数字数组
    const body = try ai.buildRequestBody(std.testing.allocator, "m", state.history.items, &.{}, "", .{});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[") == null);
}

test "绘制非法 UTF-8 不崩溃（宽容输出）" {
    var buf = try tui.render.Buffer.init(std.testing.allocator, 8, 1);
    defer buf.deinit();
    const bad = [_]u8{ 'a', 0xFF, 'b', 0xC3, 0x28 };
    const written = buf.putString(0, 0, &bad, 8, .{});
    try std.testing.expect(written > 0);
}

test "集成：HTTP 400 错误路径（需本地 mock 服务器 127.0.0.1:18124）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    // mock 脚本会在启动时写标记文件；没有标记就不连接（避免无谓的报错噪声）
    std.Io.Dir.cwd().access(io, "test/mock_18124.running", .{}) catch return error.SkipZigTest;

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    defer {
        state.config.deinit(std.testing.allocator);
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        state.stream_buf.deinit(std.testing.allocator);
        state.stream_reasoning_buf.deinit(std.testing.allocator);
        state.clearStreamEventsLocked();
        state.stream_events.deinit(std.testing.allocator);
    }

    _ = state.config.appendProvider(std.testing.allocator, .{ .name = "mock400", .endpoint = "http://127.0.0.1:18124/v1" });
    state.config.setCurrentProvider(std.testing.allocator, "mock400");
    state.config.setCurrentModel(std.testing.allocator, "mock-model");

    state.askAI("触发 400");

    var guard: usize = 0;
    while (state.streamStatus() != .idle and guard < 800) : (guard += 1) {
        state.pumpStream();
        Io.sleep(io, Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    var saw_server_error = false;
    var saw_detail = false;
    for (state.messages.items) |m| {
        if (std.mem.indexOf(u8, m.content, "ServerError") != null) saw_server_error = true;
        if (std.mem.indexOf(u8, m.content, "mock 400") != null) saw_detail = true;
    }
    if (!saw_server_error) return error.SkipZigTest;
    try std.testing.expect(saw_detail);
}

test "集成：响应流被截断（需 mock 18126，中途断开无 [DONE]/finish_reason）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    // mock 脚本会在启动时写标记文件；没有标记就不连接（避免无谓的报错噪声）
    std.Io.Dir.cwd().access(io, "test/mock_18126.running", .{}) catch return error.SkipZigTest;

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    defer {
        state.config.deinit(std.testing.allocator);
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        state.stream_buf.deinit(std.testing.allocator);
        state.stream_reasoning_buf.deinit(std.testing.allocator);
        state.clearStreamEventsLocked();
        state.stream_events.deinit(std.testing.allocator);
    }

    _ = state.config.appendProvider(std.testing.allocator, .{ .name = "mock126", .endpoint = "http://127.0.0.1:18126/v1" });
    state.config.setCurrentProvider(std.testing.allocator, "mock126");
    state.config.setCurrentModel(std.testing.allocator, "mock-model");

    state.askAI("触发截断");

    var guard: usize = 0;
    while (state.streamStatus() != .idle and guard < 1000) : (guard += 1) {
        state.pumpStream();
        Io.sleep(io, Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(StreamStatus.idle, state.streamStatus());

    // 关键断言：必须显式报"连接中断/截断"，而不是静默地当成正常结束
    var saw_truncated = false;
    var saw_checklist = false;
    var saw_failed = false;
    for (state.messages.items) |m| {
        if (std.mem.indexOf(u8, m.content, "响应流未正常结束") != null) saw_truncated = true;
        if (std.mem.indexOf(u8, m.content, "请检查: 1)") != null) saw_checklist = true;
        if (std.mem.indexOf(u8, m.content, "AI 请求失败") != null) saw_failed = true;
    }
    try std.testing.expect(saw_truncated);
    try std.testing.expect(!saw_failed); // 截断使用友好文案，不走通用失败格式
    try std.testing.expect(!saw_checklist); // 截断属瞬时问题，不显示配置检查清单
}

test "工具块：内容构建与底色渲染" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    // shell 块：标题 + 输出
    try std.testing.expect(state.beginToolBlock("bash", "{\"command\":\"echo hi\"}", .shell));
    try std.testing.expect(state.appendToolBlockBody(.shell, "hi\nthere", false));
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("$ echo hi\nhi\nthere", state.messages.items[0].content);
    try std.testing.expectEqual(@as(usize, 3), messageRowCount(state.messages.items[0], 80));

    // diff 块：上下文/删除/新增 三种底色
    try std.testing.expect(state.beginToolBlock("edit", "{\"path\":\"a.txt\"}", .diff));
    try std.testing.expect(state.appendToolBlockBody(.diff, "    1   ctx\n    2 - old\n    2 + new", false));
    const content = state.messages.items[1].content;
    try std.testing.expectEqual(@as(usize, 4), messageRowCount(state.messages.items[1], 80));

    var buf = try tui.render.Buffer.init(std.testing.allocator, 24, 3);
    defer buf.deinit();
    const area = Rect{ .x = 0, .y = 0, .width = 24, .height = 3 };
    drawToolBlockRow(&state, &buf, area, 1, content, "    1   ctx", 1, .diff, false, 0);
    drawToolBlockRow(&state, &buf, area, 1, content, "    2 - old", 2, .diff, false, 1);
    drawToolBlockRow(&state, &buf, area, 1, content, "    2 + new", 3, .diff, false, 2);

    const block_bg = tui.style.Color{ .rgb = .{ .r = 20, .g = 20, .b = 20 } };
    const removed_bg = tui.style.Color{ .rgb = .{ .r = 70, .g = 20, .b = 30 } };
    const added_bg = tui.style.Color{ .rgb = .{ .r = 20, .g = 60, .b = 30 } };
    try std.testing.expect(buf.get(0, 0).?.bg.eql(block_bg));
    try std.testing.expect(buf.get(0, 1).?.bg.eql(removed_bg));
    try std.testing.expect(buf.get(0, 2).?.bg.eql(added_bg));
    // 整行铺满底色
    try std.testing.expect(buf.get(23, 1).?.bg.eql(removed_bg));

    // 错误块：标题行标红
    const red = tui.style.Color.red;
    drawToolBlockRow(&state, &buf, area, 1, content, "← Edit a.txt", 0, .diff, true, 0);
    try std.testing.expect(buf.get(0, 0).?.fg.eql(red));
}

test "diff 行分类：内容以 '- ' 开头不误判（markdown 列表场景）" {
    // 上下文行内容以 "- " 开头 → 仍为 context（旧实现按子串搜 " - " 会误判为删除）
    try std.testing.expectEqual(DiffLineKind.context, diffLineKind("   73   - 工具没有确认环节"));
    try std.testing.expectEqual(DiffLineKind.context, diffLineKind("   74   - 提供商预设基本未经实测"));
    // 删除行内容以 "- " 开头 → removed
    try std.testing.expectEqual(DiffLineKind.removed, diffLineKind("   75 - - prompt 缓存亲和、工具输出折叠"));
    // 新增行内容以 "- " 开头 → added（旧实现先命中内容里的 " - "，误判为 removed）
    try std.testing.expectEqual(DiffLineKind.added, diffLineKind("   75 + - prompt 缓存亲和、工具输出折叠"));
    // 内容中部出现 " - " 同样不受影响
    try std.testing.expectEqual(DiffLineKind.context, diffLineKind("   76   说明 - 细节"));
    try std.testing.expectEqual(DiffLineKind.added, diffLineKind("   76 + 说明 - 细节"));
    // 常规三态
    try std.testing.expectEqual(DiffLineKind.context, diffLineKind("    1   ctx"));
    try std.testing.expectEqual(DiffLineKind.removed, diffLineKind("    2 - old"));
    try std.testing.expectEqual(DiffLineKind.added, diffLineKind("    2 + new"));
    // 行号超过 5 位（{d:>5} 不再补空格）
    try std.testing.expectEqual(DiffLineKind.removed, diffLineKind("100000 - x"));
    // elide 行
    try std.testing.expectEqual(DiffLineKind.elide, diffLineKind("     …"));
}

test "diff 渲染：列表项上下文不染色、带 - 的新增行仍绿" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }
    try std.testing.expect(state.beginToolBlock("edit", "{\"path\":\"README.md\"}", .diff));
    try std.testing.expect(state.appendToolBlockBody(.diff, "   73   - 工具没有确认环节\n   75 - - 旧行\n   75 + - 新行", false));
    const content = state.messages.items[0].content;

    var buf = try tui.render.Buffer.init(std.testing.allocator, 40, 3);
    defer buf.deinit();
    const area = Rect{ .x = 0, .y = 0, .width = 40, .height = 3 };
    drawToolBlockRow(&state, &buf, area, 0, content, "   73   - 工具没有确认环节", 1, .diff, false, 0);
    drawToolBlockRow(&state, &buf, area, 0, content, "   75 - - 旧行", 2, .diff, false, 1);
    drawToolBlockRow(&state, &buf, area, 0, content, "   75 + - 新行", 3, .diff, false, 2);

    const block_bg = tui.style.Color{ .rgb = .{ .r = 20, .g = 20, .b = 20 } };
    const removed_bg = tui.style.Color{ .rgb = .{ .r = 70, .g = 20, .b = 30 } };
    const added_bg = tui.style.Color{ .rgb = .{ .r = 20, .g = 60, .b = 30 } };
    try std.testing.expect(buf.get(0, 0).?.bg.eql(block_bg)); // 列表项上下文：默认底色
    try std.testing.expect(buf.get(0, 1).?.bg.eql(removed_bg));
    try std.testing.expect(buf.get(0, 2).?.bg.eql(added_bg));
}

test "工具块：shell 标题自动折行渲染（含上限）" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    state.message_wrap_width = 20;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    // "$ " + 40 字符 = 42 → 宽 20 → 3 行
    try std.testing.expect(state.beginToolBlock("bash", "{\"command\":\"0123456789012345678901234567890123456789\"}", .shell));
    try std.testing.expectEqual(@as(usize, 3), messageRowCount(state.messages.items[0], 20));

    var buf = try tui.render.Buffer.init(std.testing.allocator, 20, 4);
    defer buf.deinit();
    drawMessages(&state, Rect{ .x = 0, .y = 0, .width = 20, .height = 4 }, &buf);

    // 首行以 $ 开头，续行保持标题样式（青色）
    try std.testing.expectEqual(@as(u21, '$'), buf.get(0, 0).?.char);
    const cyan = tui.style.Color.light_cyan;
    try std.testing.expect(buf.get(0, 1).?.fg.eql(cyan));
    try std.testing.expect(buf.get(0, 2).?.fg.eql(cyan));

    // 超长标题：折行数封顶，最后一行以 … 收尾
    const long_cmd: [200]u8 = @splat('x');
    var args_buf: [256]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "{{\"command\":\"{s}\"}}", .{long_cmd}) catch unreachable;
    try std.testing.expect(state.beginToolBlock("bash", args, .shell));
    try std.testing.expectEqual(@as(usize, shell_header_max_rows), messageRowCount(state.messages.items[1], 20));
}

test "工具调用行格式（单行摘要）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "→ Read src/main.zig [limit=30, offset=2012]",
        formatToolCallLine(a, "read", "{\"path\":\"src/main.zig\",\"offset\":2012,\"limit\":30}"),
    );
    try std.testing.expectEqualStrings(
        "→ Read src/main.zig",
        formatToolCallLine(a, "read", "{\"path\":\"src/main.zig\"}"),
    );
    try std.testing.expectEqualStrings(
        "→ Grep \"fn main\" [glob=*.zig, ignore_case, literal]",
        formatToolCallLine(a, "grep", "{\"pattern\":\"fn main\",\"glob\":\"*.zig\",\"ignore_case\":true,\"literal\":true}"),
    );
    try std.testing.expectEqualStrings(
        "→ Grep \"TODO\" [path=src]",
        formatToolCallLine(a, "grep", "{\"pattern\":\"TODO\",\"path\":\"src\"}"),
    );
    try std.testing.expectEqualStrings(
        "→ Find **/*.zig [path=src]",
        formatToolCallLine(a, "find", "{\"pattern\":\"**/*.zig\",\"path\":\"src\"}"),
    );
    try std.testing.expectEqualStrings(
        "→ List .",
        formatToolCallLine(a, "ls", "{\"path\":\".\"}"),
    );
    try std.testing.expectEqualStrings(
        "→ List src",
        formatToolCallLine(a, "ls", "{\"path\":\"src\"}"),
    );
    try std.testing.expectEqualStrings(
        "→ Write a.txt (5B)",
        formatToolCallLine(a, "write", "{\"path\":\"a.txt\",\"content\":\"hello\"}"),
    );
    // 大小统计：1234 字节 → 1.2KB
    const big: [1234]u8 = @splat('x');
    var args_buf: [1400]u8 = undefined;
    const big_args = std.fmt.bufPrint(&args_buf, "{{\"path\":\"a.txt\",\"content\":\"{s}\"}}", .{big}) catch unreachable;
    try std.testing.expectEqualStrings(
        "→ Write a.txt (1.2KB)",
        formatToolCallLine(a, "write", big_args),
    );
}

test "加载历史：工具交互恢复与 system prompt 升级" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    const rows = [_]db_mod.MessageRow{
        .{ .id = 1, .role = "system", .content = "OLD PROMPT" },
        .{ .id = 2, .role = "user", .content = "列出文件" },
        .{ .id = 3, .role = "assistant", .content = "", .tool_calls = "[{\"id\":\"call_1\",\"name\":\"ls\",\"arguments\":\"{\\\"path\\\":\\\".\\\"}\"}]" },
        .{ .id = 4, .role = "tool", .content = "src/\n", .tool_call_id = "call_1", .tool_name = "ls", .is_error = 0 },
        .{ .id = 5, .role = "assistant", .content = "目录里有 src/", .reasoning = "先看看", .reasoning_ms = 800 },
        // bash 工具块（正文即原始输出）
        .{ .id = 6, .role = "assistant", .content = "", .tool_calls = "[{\"id\":\"call_2\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"}]" },
        .{ .id = 7, .role = "tool", .content = "hi\n", .tool_call_id = "call_2", .tool_name = "bash", .is_error = 0 },
        // edit 工具块（正文来自落库的 diff）
        .{ .id = 8, .role = "assistant", .content = "", .tool_calls = "[{\"id\":\"call_3\",\"name\":\"edit\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}]" },
        .{ .id = 9, .role = "tool", .content = "Successfully replaced 1 block(s) in a.txt.", .tool_call_id = "call_3", .tool_name = "edit", .tool_display = "    1 - old\n    1 + new", .is_error = 0 },
    };
    state.applyLoadedMessages(&rows);

    // 历史：system 升级；工具字段恢复
    try std.testing.expectEqual(@as(usize, 9), state.history.items.len);
    try std.testing.expectEqualStrings(system_prompt, state.history.items[0].content);
    try std.testing.expect(state.history.items[2].tool_calls != null);
    try std.testing.expectEqualStrings("ls", state.history.items[2].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("call_1", state.history.items[3].tool_call_id.?);

    // 界面：⚙/↳ 提示行 + 最终回答
    var joined = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer joined.deinit(std.testing.allocator);
    for (state.messages.items) |m| {
        try joined.appendSlice(std.testing.allocator, m.content);
        try joined.append(std.testing.allocator, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "→ List . (5B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "↳ 完成") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "目录里有 src/") != null);

    // 工具块重建：bash → shell 块（标题 + 输出），edit → diff 块（- / + 行）
    var shell: ?Message = null;
    var diff: ?Message = null;
    for (state.messages.items) |m| {
        if (m.tool_block == .shell) shell = m;
        if (m.tool_block == .diff) diff = m;
    }
    try std.testing.expect(shell != null);
    try std.testing.expect(std.mem.indexOf(u8, shell.?.content, "$ echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell.?.content, "hi") != null);
    try std.testing.expect(diff != null);
    try std.testing.expect(std.mem.indexOf(u8, diff.?.content, "← Edit a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff.?.content, "    1 - old") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff.?.content, "    1 + new") != null);
    try std.testing.expectEqual(@as(usize, 3), messageRowCount(diff.?, 80));
}

test "工具调用 JSON 往返" {
    const calls = [_]ai.ToolCall{
        .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a b.txt\"}" },
        .{ .id = "call_2", .name = "ls", .arguments = "{}" },
    };
    const json = try toolCallsToJson(std.testing.allocator, &calls);
    defer std.testing.allocator.free(json);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const back = parseToolCalls(arena_state.allocator(), json).?;
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("call_1", back[0].id);
    try std.testing.expectEqualStrings("read", back[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a b.txt\"}", back[0].arguments);
    try std.testing.expectEqualStrings("call_2", back[1].id);
}

test "集成：工具调用循环（需本地 mock 服务器 127.0.0.1:18123）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    // mock 脚本会在启动时写标记文件；没有标记就不连接（避免无谓的报错噪声）
    std.Io.Dir.cwd().access(io, "test/mock_18123.running", .{}) catch return error.SkipZigTest;

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;

    // 真实落库验证：用临时数据库跑完整回合
    const db_path = "skynet_test_integration.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_integration.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_integration.db-shm") catch {};
    state.db = db_mod.Db.openFile(std.testing.allocator, io, db_path) catch null;
    state.session_id = if (state.db != null) (state.db.?.createSession("") catch 0) else 0;

    defer {
        if (state.db) |*d| d.deinit();
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_integration.db-wal") catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_integration.db-shm") catch {};
        state.config.deinit(std.testing.allocator);
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        state.stream_buf.deinit(std.testing.allocator);
        state.stream_reasoning_buf.deinit(std.testing.allocator);
        state.clearStreamEventsLocked();
        state.stream_events.deinit(std.testing.allocator);
    }

    // preset=openai：验证缓存参数（prompt_cache_key）、会话亲和头与流式 usage 确实发出
    _ = state.config.appendProvider(std.testing.allocator, .{
        .name = "mock",
        .endpoint = "http://127.0.0.1:18123/v1",
        .preset = "openai",
    });
    state.config.setCurrentProvider(std.testing.allocator, "mock");
    state.config.setCurrentModel(std.testing.allocator, "mock-model");

    state.askAI("列一下目录");

    var guard: usize = 0;
    while (state.streamStatus() != .idle and guard < 1500) : (guard += 1) {
        state.pumpStream();
        Io.sleep(io, Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    // 没有本地 mock 服务器时（连接失败）跳过，其余失败照常报错
    var connection_failure = false;
    for (state.messages.items) |m| {
        if (std.mem.indexOf(u8, m.content, "NetworkError") != null or
            std.mem.indexOf(u8, m.content, "Unexpected") != null) connection_failure = true;
    }
    if (connection_failure) return error.SkipZigTest;
    try std.testing.expectEqual(StreamStatus.idle, state.streamStatus());

    var display = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer display.deinit(std.testing.allocator);
    for (state.messages.items) |m| {
        try display.appendSlice(std.testing.allocator, m.content);
        try display.append(std.testing.allocator, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, display.items, "→ List") != null);
    try std.testing.expect(std.mem.indexOf(u8, display.items, "→ List . (") != null);
    try std.testing.expect(std.mem.indexOf(u8, display.items, "目录里有文件") != null);
    try std.testing.expect(std.mem.indexOf(u8, display.items, "MOCK_ERROR") == null);

    // usage：mock 每轮返回 prompt 100 / cached 80，三轮累计；上下文占用只取最后一轮
    try std.testing.expect(state.last_usage.input_tokens > 0);
    try std.testing.expect(state.last_usage.cached_tokens > 0);
    try std.testing.expect(state.last_usage.cached_tokens <= state.last_usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 100), state.context_usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 300), state.last_usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 80), state.context_usage.cached_tokens);

    // bash 工具块：标题 + 输出在同一块消息内
    var shell_block: ?Message = null;
    for (state.messages.items) |m| {
        if (m.tool_block == .shell) shell_block = m;
    }
    try std.testing.expect(shell_block != null);
    try std.testing.expect(std.mem.indexOf(u8, shell_block.?.content, "$ Write-Output mock-out") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell_block.?.content, "mock-out") != null);
    try std.testing.expectEqual(@as(usize, 2), messageRowCount(shell_block.?, 80));

    // 每个工具轮次 + 最终回复的思考都要显示（live），且请求结束后全部自动折叠
    var live_r1 = false;
    var live_r2 = false;
    var live_final = false;
    for (state.messages.items) |m| {
        if (m.reasoning) |r| {
            try std.testing.expect(!m.reasoning_expanded); // auto：思考结束后折叠
            if (std.mem.indexOf(u8, r, "让我先想想") != null) live_r1 = true;
            if (std.mem.indexOf(u8, r, "再看命令输出") != null) live_r2 = true;
            if (std.mem.indexOf(u8, r, "信息齐了") != null) live_final = true;
        }
    }
    try std.testing.expect(live_r1);
    try std.testing.expect(live_r2);
    try std.testing.expect(live_final);

    var saw_tool_msg = false;
    var saw_tool_calls = false;
    for (state.history.items) |m| {
        if (std.mem.eql(u8, m.role, "tool")) saw_tool_msg = true;
        if (m.tool_calls != null) saw_tool_calls = true;
    }
    try std.testing.expect(saw_tool_msg);
    try std.testing.expect(saw_tool_calls);

    // 落库验证：工具调用与工具结果都已持久化；每轮思考也要落库（重启可见）
    if (state.db) |*db| {
        const persisted = db.loadMessages(state.session_id) catch &.{};
        var db_calls = false;
        var db_tool = false;
        var db_r1 = false;
        var db_r2 = false;
        var db_final = false;
        for (persisted) |m| {
            if (std.mem.eql(u8, m.role, "assistant") and m.tool_calls.len > 0) {
                db_calls = true;
                if (std.mem.indexOf(u8, m.reasoning, "让我先想想") != null) db_r1 = true;
                if (std.mem.indexOf(u8, m.reasoning, "再看命令输出") != null) db_r2 = true;
            }
            if (std.mem.eql(u8, m.role, "tool") and m.tool_call_id.len > 0) db_tool = true;
            if (std.mem.eql(u8, m.role, "assistant") and m.tool_calls.len == 0 and
                std.mem.indexOf(u8, m.reasoning, "信息齐了") != null) db_final = true;
        }
        try std.testing.expect(db_calls);
        try std.testing.expect(db_tool);
        try std.testing.expect(db_r1);
        try std.testing.expect(db_r2);
        try std.testing.expect(db_final);
    }
}

test "生成中回车排队：入队+显示+清空输入；指令与空输入保持忽略" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    state.input.allocator = std.testing.allocator;
    defer {
        state.clearPendingSends();
        state.pending_sends.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        state.input.deinit();
    }

    // 模拟流式进行中
    state.setStreamStatus(.running);

    // 回车：消息入队 + 立即上屏 + 输入框清空
    // （last_key_ms 置 0：模拟人类按键间隔，避免被"粘贴换行"启发式误判）
    state.input.insertBytes("生成中插一句");
    state.last_key_ms = 0;
    state.handleNormalKey(.{ .code = .enter });
    try std.testing.expectEqual(@as(usize, 1), state.pending_sends.items.len);
    try std.testing.expectEqualStrings("生成中插一句", state.pending_sends.items[0]);
    try std.testing.expectEqual(@as(usize, 0), state.input.value().len);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expect(state.messages.items[0].user);
    try std.testing.expectEqualStrings("生成中插一句", state.messages.items[0].content);

    // 指令：生成中保持忽略（不排队、不清空输入）
    state.input.insertBytes("/help");
    state.last_key_ms = 0;
    state.handleNormalKey(.{ .code = .enter });
    try std.testing.expectEqual(@as(usize, 1), state.pending_sends.items.len);
    try std.testing.expectEqualStrings("/help", state.input.value());

    // 空输入：无动作
    state.input.clear();
    state.last_key_ms = 0;
    state.handleNormalKey(.{ .code = .enter });
    try std.testing.expectEqual(@as(usize, 1), state.pending_sends.items.len);

    // 连续提交：FIFO 排队
    state.input.insertBytes("第二条");
    state.last_key_ms = 0;
    state.handleNormalKey(.{ .code = .enter });
    try std.testing.expectEqual(@as(usize, 2), state.pending_sends.items.len);
    try std.testing.expectEqualStrings("生成中插一句", state.pending_sends.items[0]);
    try std.testing.expectEqualStrings("第二条", state.pending_sends.items[1]);
}

test "排队消息：FIFO 取用/清空；flush 在无提供商或生成中时不取走" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    defer {
        state.clearPendingSends();
        state.pending_sends.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    state.queuePendingSend("第一条");
    state.queuePendingSend("第二条");
    try std.testing.expectEqual(@as(usize, 2), state.pending_sends.items.len);

    // flush：未配置提供商 → 保留队列、不取走
    state.flushPendingSends();
    try std.testing.expectEqual(@as(usize, 2), state.pending_sends.items.len);

    // flush：生成中 → 保留队列
    state.setStreamStatus(.running);
    state.flushPendingSends();
    try std.testing.expectEqual(@as(usize, 2), state.pending_sends.items.len);
    state.setStreamStatus(.idle);

    // FIFO 取用
    const first = state.takeFirstPendingSend().?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("第一条", first);
    const second = state.takeFirstPendingSend().?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("第二条", second);
    try std.testing.expect(state.takeFirstPendingSend() == null);

    // clear 释放全部
    state.queuePendingSend("第三条");
    state.clearPendingSends();
    try std.testing.expectEqual(@as(usize, 0), state.pending_sends.items.len);
}

test "排队消息：生成中提交，在工具轮次间注入（需本地 mock 18123）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    std.Io.Dir.cwd().access(io, "test/mock_18123.running", .{}) catch return error.SkipZigTest;

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;

    const db_path = "skynet_test_pending_send.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_pending_send.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_pending_send.db-shm") catch {};
    state.db = db_mod.Db.openFile(std.testing.allocator, io, db_path) catch null;
    state.session_id = if (state.db != null) (state.db.?.createSession("") catch 0) else 0;

    defer {
        if (state.db) |*d| d.deinit();
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_pending_send.db-wal") catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_pending_send.db-shm") catch {};
        state.config.deinit(std.testing.allocator);
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        state.stream_buf.deinit(std.testing.allocator);
        state.stream_reasoning_buf.deinit(std.testing.allocator);
        state.clearStreamEventsLocked();
        state.stream_events.deinit(std.testing.allocator);
        state.clearPendingSends();
        state.pending_sends.deinit(std.testing.allocator);
    }

    _ = state.config.appendProvider(std.testing.allocator, .{
        .name = "mock",
        .endpoint = "http://127.0.0.1:18123/v1",
        .preset = "openai",
    });
    state.config.setCurrentProvider(std.testing.allocator, "mock");
    state.config.setCurrentModel(std.testing.allocator, "mock-model");

    const queued_text = "顺便说一句：多留意缓存";
    state.askAI("列一下目录");

    // 泵到首个工具块出现（第一轮工具已执行），此时提交排队消息
    var saw_block = false;
    var conn_fail = false;
    var guard: usize = 0;
    while (guard < 2000 and !saw_block and !conn_fail) : (guard += 1) {
        state.pumpStream();
        for (state.messages.items) |m| {
            if (m.tool_block != null) saw_block = true;
            if (std.mem.indexOf(u8, m.content, "NetworkError") != null or
                std.mem.indexOf(u8, m.content, "Unexpected") != null) conn_fail = true;
        }
        Io.sleep(io, Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    if (conn_fail) return error.SkipZigTest;
    try std.testing.expect(saw_block);

    state.queuePendingSend(queued_text);
    try std.testing.expectEqual(@as(usize, 1), state.pending_sends.items.len);

    // 泵到底
    guard = 0;
    while (state.streamStatus() != .idle and guard < 2000) : (guard += 1) {
        state.pumpStream();
        Io.sleep(io, Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqual(StreamStatus.idle, state.streamStatus());
    // 队列已被 worker 在轮次边界取走
    try std.testing.expectEqual(@as(usize, 0), state.pending_sends.items.len);

    // 历史：恰好一次，且位于首个 assistant 与最后 assistant 之间（轮次间注入，而非轮尾追加）
    var q_idx: ?usize = null;
    var first_a: ?usize = null;
    var last_a: ?usize = null;
    var q_count: usize = 0;
    for (state.history.items, 0..) |m, i| {
        if (std.mem.eql(u8, m.role, "assistant")) {
            if (first_a == null) first_a = i;
            last_a = i;
        }
        if (std.mem.eql(u8, m.content, queued_text)) {
            q_count += 1;
            q_idx = i;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), q_count);
    try std.testing.expect(first_a != null and last_a != null);
    try std.testing.expect(first_a.? < q_idx.?);
    try std.testing.expect(q_idx.? < last_a.?);

    // 显示：恰好一次（提交时上屏，注入时不重复）
    var display_count: usize = 0;
    for (state.messages.items) |m| {
        if (std.mem.eql(u8, m.content, queued_text)) display_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), display_count);

    // 落库：恰好一次（worker 实时落库）
    if (state.db) |*db| {
        const rows = db.loadMessages(state.session_id) catch &.{};
        var db_count: usize = 0;
        for (rows) |r| {
            if (std.mem.eql(u8, r.role, "user") and std.mem.eql(u8, r.content, queued_text)) db_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), db_count);
    }
}

test "排队消息：无活动生成时 flush 作为新回合发出（需本地 mock 18123）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    std.Io.Dir.cwd().access(io, "test/mock_18123.running", .{}) catch return error.SkipZigTest;

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;

    const db_path = "skynet_test_pending_flush.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_pending_flush.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_pending_flush.db-shm") catch {};
    state.db = db_mod.Db.openFile(std.testing.allocator, io, db_path) catch null;
    state.session_id = if (state.db != null) (state.db.?.createSession("") catch 0) else 0;

    defer {
        if (state.db) |*d| d.deinit();
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_pending_flush.db-wal") catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_pending_flush.db-shm") catch {};
        state.config.deinit(std.testing.allocator);
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        state.stream_buf.deinit(std.testing.allocator);
        state.stream_reasoning_buf.deinit(std.testing.allocator);
        state.clearStreamEventsLocked();
        state.stream_events.deinit(std.testing.allocator);
        state.clearPendingSends();
        state.pending_sends.deinit(std.testing.allocator);
    }

    _ = state.config.appendProvider(std.testing.allocator, .{
        .name = "mock",
        .endpoint = "http://127.0.0.1:18123/v1",
        .preset = "openai",
    });
    state.config.setCurrentProvider(std.testing.allocator, "mock");
    state.config.setCurrentModel(std.testing.allocator, "mock-model");

    const queued_text = "排队后自动发送";
    state.queuePendingSend(queued_text);
    try std.testing.expectEqual(@as(usize, 1), state.pending_sends.items.len);

    // 轮尾 flush：取走最早一条并立即发起新回合
    state.flushPendingSends();
    try std.testing.expectEqual(StreamStatus.running, state.streamStatus());
    try std.testing.expectEqual(@as(usize, 0), state.pending_sends.items.len);

    // 泵到底
    var guard: usize = 0;
    while (state.streamStatus() != .idle and guard < 2000) : (guard += 1) {
        state.pumpStream();
        Io.sleep(io, Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    var conn_fail = false;
    for (state.messages.items) |m| {
        if (std.mem.indexOf(u8, m.content, "NetworkError") != null or
            std.mem.indexOf(u8, m.content, "Unexpected") != null) conn_fail = true;
    }
    if (conn_fail) return error.SkipZigTest;
    try std.testing.expectEqual(StreamStatus.idle, state.streamStatus());

    // 历史：作为本回合的 user 消息恰好一次，位于首个 assistant 之前
    var q_count: usize = 0;
    var q_idx: ?usize = null;
    var first_a: ?usize = null;
    for (state.history.items, 0..) |m, i| {
        if (std.mem.eql(u8, m.role, "assistant") and first_a == null) first_a = i;
        if (std.mem.eql(u8, m.content, queued_text)) {
            q_count += 1;
            q_idx = i;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), q_count);
    try std.testing.expect(first_a != null);
    try std.testing.expect(q_idx.? < first_a.?);

    // 显示恰好一次（排队时上屏，flush 不再重复上屏）
    var display_count: usize = 0;
    for (state.messages.items) |m| {
        if (std.mem.eql(u8, m.content, queued_text)) display_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), display_count);
}

test "粘贴换行判定：突发间隔视为粘贴" {
    try std.testing.expect(isPasteNewline(0));
    try std.testing.expect(isPasteNewline(5));
    try std.testing.expect(isPasteNewline(19));
    try std.testing.expect(!isPasteNewline(20));
    try std.testing.expect(!isPasteNewline(200));
}

test "粘贴文本：清洗非法 UTF-8 + 表单字段可粘贴" {
    var state = AppState{};
    state.allocator = std.testing.allocator;

    // 合法文本直接插入
    _ = insertPastedText(state.allocator, &state.provider_form_key, "sk-abc123");
    try std.testing.expectEqualStrings("sk-abc123", state.provider_form_key.value());

    // 非法字节（GBK）替换为 U+FFFD，不污染输入
    _ = insertPastedText(state.allocator, &state.provider_form_key, "sk-\xB7x");
    try std.testing.expectEqualStrings("sk-abc123sk-\u{FFFD}x", state.provider_form_key.value());
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.provider_form_key.value()));

    // 表单焦点字段路由：第 3 栏（env）粘贴
    state.provider_form_field = 3;
    _ = insertPastedText(state.allocator, state.providerFormActiveInput(), "OPENAI_API_KEY");
    try std.testing.expectEqualStrings("OPENAI_API_KEY", state.provider_form_key_env.value());

    // 大粘贴：动态缓冲完整保留（超过旧的 64KB 固定上限）
    state.input.allocator = std.testing.allocator;
    defer state.input.deinit();
    const big = try std.testing.allocator.alloc(u8, 200 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    state.input.clear();
    const inserted = insertPastedText(state.allocator, &state.input, big);
    try std.testing.expectEqual(big.len, inserted);
    try std.testing.expectEqual(big.len, state.input.value().len);
}

test "选中文本提取：跨消息、反向、截断" {
    const contents = [_][]const u8{ "hello", "world", "!!" };
    const no_reasoning = [_][]const u8{ "", "", "" };

    // 同一消息
    const a = try extractSelectionText(std.testing.allocator, &contents, &no_reasoning, .{ .msg = 0, .off = 1 }, .{ .msg = 0, .off = 4 });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("ell", a);

    // 反向选择（从后往前拖）
    const b = try extractSelectionText(std.testing.allocator, &contents, &no_reasoning, .{ .msg = 1, .off = 4 }, .{ .msg = 0, .off = 2 });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("llo\nworl", b);

    // 跨三条消息
    const c = try extractSelectionText(std.testing.allocator, &contents, &no_reasoning, .{ .msg = 0, .off = 4 }, .{ .msg = 2, .off = 1 });
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("o\nworld\n!", c);

    // 偏移越界自动裁剪（start 被裁到消息末尾后该消息贡献为空）
    const d = try extractSelectionText(std.testing.allocator, &contents, &no_reasoning, .{ .msg = 0, .off = 99 }, .{ .msg = 2, .off = 99 });
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("world\n!!", d);
}

test "选中文本提取：跨思考块与正文" {
    const contents = [_][]const u8{ "答案A", "答案B" };
    const reasonings = [_][]const u8{ "思考甲", "" };

    // 思考块内部（"思考甲" 每字 3 字节）
    const a = try extractSelectionText(std.testing.allocator, &contents, &reasonings, .{ .msg = 0, .source = .reasoning, .off = 6 }, .{ .msg = 0, .source = .reasoning, .off = 9 });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("甲", a);

    // 思考块 → 同一条消息的正文（视觉顺序：思考在前）
    const b = try extractSelectionText(std.testing.allocator, &contents, &reasonings, .{ .msg = 0, .source = .reasoning, .off = 6 }, .{ .msg = 0, .source = .content, .off = 3 });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("甲\n答", b);

    // 上面的正文 → 下一条的思考 → 再下一条的正文
    const c = try extractSelectionText(std.testing.allocator, &contents, &reasonings, .{ .msg = 0, .source = .content, .off = 3 }, .{ .msg = 1, .source = .content, .off = 3 });
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("案A\n答", c);

    // 反向跨来源（从正文往上拖回思考块）
    const d = try extractSelectionText(std.testing.allocator, &contents, &reasonings, .{ .msg = 0, .source = .content, .off = 3 }, .{ .msg = 0, .source = .reasoning, .off = 6 });
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("甲\n答", d);
}

test "选区列偏移换算（含宽字符）" {
    // "a中b" 显示宽度 4（a=1,中=2,b=1）
    const seg = SelSegment{ .text = "a中b", .x = 0, .width = 4, .off = 0 };
    try std.testing.expectEqual(@as(usize, 0), offsetInSegment(seg, 0));
    try std.testing.expectEqual(@as(usize, 1), offsetInSegment(seg, 1)); // 中 的起始
    try std.testing.expectEqual(@as(usize, 1), offsetInSegment(seg, 2)); // 中 的第二列
    try std.testing.expectEqual(@as(usize, 4), offsetInSegment(seg, 3)); // b
    try std.testing.expectEqual(@as(usize, 5), offsetInSegment(seg, 4)); // 行尾
}

test "表格行选择映射：折叠非内容片段后各列均可映射" {
    const content = "| 方法 | 时间复杂度 | 空间复杂度 | 适用场景 |\n|------|------------|------------|----------|\n| 迭代法 | O(n) | O(1) | 推荐 |";
    const lines = try md_mod.parse(std.testing.allocator, content, md_mod.default_styles);
    defer md_mod.free(std.testing.allocator, lines);

    var state = AppState{};
    const header_line = &lines[0]; // 整张表是第 0 行；物理行 1 为表头（0 是上边框）
    recordMdRow(&state, 0, content, header_line, 100, 1, 0, 0);

    const row = &state.sel_rows[0];
    // 4 个单元格各留下一个内容片段（边框/填充已折叠）
    try std.testing.expectEqual(@as(u8, 4), row.seg_count);
    try std.testing.expectEqualStrings("方法", row.segs[0].text);
    try std.testing.expectEqualStrings("时间复杂度", row.segs[1].text);
    try std.testing.expectEqualStrings("空间复杂度", row.segs[2].text);
    try std.testing.expectEqualStrings("适用场景", row.segs[3].text);

    // 点击最后一列内部应命中该列内容偏移
    const last = row.segs[3];
    const hit = pointInRow(row, last.x + 1).?;
    try std.testing.expectEqual(last.off, hit.off);
}

test "拖选跨过无映射行时取距离最近的文本行" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    // 行映射必须指向真实消息缓冲（陈旧指针会被 rowSegmentsLive 拦截）
    const content = try std.testing.allocator.dupe(u8, "text");
    try state.messages.append(std.testing.allocator, .{ .content = content, .style = .{} });
    const reasoning = try std.testing.allocator.dupe(u8, "text");
    try state.messages.append(std.testing.allocator, .{ .content = "", .style = .{}, .reasoning = reasoning });

    const mk = struct {
        fn row(msg: usize, y: u16, source: SelSource, text: []const u8) SelRow {
            var r = SelRow{ .y = y, .msg = msg, .source = source, .seg_count = 1 };
            r.segs[0] = .{ .text = text, .x = 0, .width = 4, .off = 0 };
            return r;
        }
    };
    state.sel_rows[0] = mk.row(0, 10, .content, content);
    state.sel_rows[1] = mk.row(1, 14, .reasoning, reasoning);
    state.sel_rows[2] = mk.row(0, 16, .content, content);
    state.sel_row_count = 3;

    // y=12（无映射行，如 Thought 表头/空行）：同距优先下方 → 思考内容行
    const p = state.pointFromScreen(1, 12).?;
    try std.testing.expectEqual(SelSource.reasoning, p.source);
    try std.testing.expectEqual(@as(usize, 1), p.off);

    // 区域下方：取最后一行
    const p2 = state.pointFromScreen(1, 19).?;
    try std.testing.expectEqual(SelSource.content, p2.source);
    try std.testing.expectEqual(@as(usize, 1), p2.off);
}

test "输入框选区：提取与列偏移（含宽字符）" {
    const text = "你好\nworld";
    // 反向、越界、裁剪（区间左闭右开）
    try std.testing.expectEqualStrings("好\nwo", extractInputSelection(text, 3, 9));
    try std.testing.expectEqualStrings("好\nworld", extractInputSelection(text, 99, 3));
    try std.testing.expectEqualStrings("", extractInputSelection(text, 5, 5));

    // 列偏移（宽字符占 2 列）
    const line = "a中b"; // 宽度 4
    try std.testing.expectEqual(@as(usize, 0), offsetInRange(line, 0, line.len, 0));
    try std.testing.expectEqual(@as(usize, 1), offsetInRange(line, 0, line.len, 1)); // 中
    try std.testing.expectEqual(@as(usize, 1), offsetInRange(line, 0, line.len, 2)); // 中的第二列
    try std.testing.expectEqual(@as(usize, 4), offsetInRange(line, 0, line.len, 3)); // b
    try std.testing.expectEqual(@as(usize, 5), offsetInRange(line, 0, line.len, 4)); // 行尾
}

test "输入框全选与选区感知删除" {
    var state = AppState{};
    state.input.insertBytes("hello 你好");
    state.selectAllInput();

    try std.testing.expect(state.sel_active);
    try std.testing.expectEqual(@as(usize, 0), state.sel_anchor.off);
    try std.testing.expectEqual(state.input.value().len, state.sel_current.off);

    // 选区删除后清空
    state.deleteInputSelection();
    try std.testing.expectEqualStrings("", state.input.value());
    try std.testing.expect(!state.sel_active);

    // 空输入时全选为无操作
    state.selectAllInput();
    try std.testing.expect(!state.sel_active);

    // 部分选区删除（反向选择也正确）
    state.input.insertBytes("abcdef");
    state.sel_area = .input;
    state.sel_active = true;
    state.sel_anchor = .{ .off = 4 };
    state.sel_current = .{ .off = 1 };
    state.deleteInputSelection();
    try std.testing.expectEqualStrings("aef", state.input.value());
}

test "Ctrl+X 剪切输入框选区：先复制后删除，失败保留原文" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    // fake 剪贴板：记录写入内容，可按需模拟失败
    const Fake = struct {
        var text: [64]u8 = undefined;
        var len: usize = 0;
        var fail: bool = false;
        fn write(_: std.mem.Allocator, s: []const u8) bool {
            if (fail) return false;
            len = @min(s.len, text.len);
            @memcpy(text[0..len], s[0..len]);
            return true;
        }
    };
    Fake.len = 0;
    Fake.fail = false;

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    state.input.allocator = std.testing.allocator;
    defer state.input.deinit();

    state.input.insertBytes("hello 你好 world");
    state.sel_area = .input;
    state.sel_active = true;
    state.sel_anchor = .{ .off = 0 };
    state.sel_current = .{ .off = "hello 你好".len };
    try std.testing.expect(state.cutSelectionWith(Fake.write));
    try std.testing.expectEqualStrings("hello 你好", Fake.text[0..Fake.len]);
    try std.testing.expectEqualStrings(" world", state.input.value());
    try std.testing.expectEqual(@as(usize, 0), state.input.cursor);
    try std.testing.expect(!state.sel_active);
    try std.testing.expect(state.toast_len > 0);

    // 剪贴板写入失败：原文与选区都保留，可重试
    Fake.fail = true;
    state.sel_area = .input;
    state.sel_active = true;
    state.sel_anchor = .{ .off = 1 };
    state.sel_current = .{ .off = 6 };
    try std.testing.expect(!state.cutSelectionWith(Fake.write));
    try std.testing.expectEqualStrings(" world", state.input.value());
    try std.testing.expect(state.sel_active);

    // 选区在消息区：输入框不受影响
    state.sel_area = .messages;
    try std.testing.expect(!state.cutSelectionWith(Fake.write));
    try std.testing.expectEqualStrings(" world", state.input.value());

    // 无选区：无操作
    state.sel_active = false;
    try std.testing.expect(!state.cutSelectionWith(Fake.write));
    try std.testing.expectEqualStrings(" world", state.input.value());
}

test "主菜单选择支持首尾循环" {
    var state = AppState{};
    state.mode = .help_select;
    state.help_select_index = 0;

    // 首项向上 → 跳到最后一项
    state.handleHelpSelectKey(.{ .code = .up });
    try std.testing.expectEqual(help_commands.len - 1, state.help_select_index);

    // 末项向下 → 跳回第一项
    state.handleHelpSelectKey(.{ .code = .down });
    try std.testing.expectEqual(@as(usize, 0), state.help_select_index);

    // 普通向下
    state.handleHelpSelectKey(.{ .code = .down });
    try std.testing.expectEqual(@as(usize, 1), state.help_select_index);
}

test "陈旧行映射防护：指针悬空时命中测试不再崩溃" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    const content = try std.testing.allocator.dupe(u8, "hello world");
    try state.messages.append(std.testing.allocator, .{ .content = content, .style = .{} });

    // 模拟上一帧留下的悬空映射（内容已被流式重分配释放）
    const stale = try std.testing.allocator.alloc(u8, content.len);
    std.testing.allocator.free(stale);
    state.sel_rows[0] = .{ .y = 5, .msg = 0, .source = .content, .seg_count = 1 };
    state.sel_rows[0].segs[0] = .{ .text = stale, .off = 0, .x = 0, .width = @intCast(content.len) };
    state.sel_row_count = 1;
    try std.testing.expect(!rowSegmentsLive(&state, &state.sel_rows[0]));
    try std.testing.expect(state.pointFromScreen(0, 5) == null);

    // 有效映射正常命中
    state.sel_row_count = 0;
    recordPlainRow(&state, 0, content, content, 0, 5);
    try std.testing.expect(rowSegmentsLive(&state, &state.sel_rows[0]));
    const p = state.pointFromScreen(1, 5).?;
    try std.testing.expectEqual(@as(usize, 0), p.msg);
    try std.testing.expectEqual(@as(usize, 1), p.off);
}

test "边缘拖动自动滚动方向判定" {
    var state = AppState{};

    // ── 消息区 ──
    state.sel_rows[0] = .{ .y = 2, .msg = 0, .seg_count = 0 };
    state.sel_rows[1] = .{ .y = 3, .msg = 0, .seg_count = 0 };
    state.sel_rows[2] = .{ .y = 4, .msg = 0, .seg_count = 0 };
    state.sel_row_count = 3;
    state.sel_dragging = true;
    state.sel_area = .messages;

    // 拖到顶端 → 向上滚动
    state.drag_y = 1;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, -1), state.auto_scroll_dir);

    // 拖到底端 → 向下滚动
    state.drag_y = 4;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, 1), state.auto_scroll_dir);

    // 区域内 → 不滚动
    state.drag_y = 3;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, 0), state.auto_scroll_dir);

    // ── 输入框 ──
    // 12 字符宽 4 → 3 行内容；可视高度 2；光标在末尾时跟随视口 = 2
    state.input.clear();
    state.input.insertBytes("aaaaaaaaaaaa");
    state.input.moveCursorEnd();
    state.input_wrap_width = 4;
    state.input_content_rows = 2;
    state.input.applyViewport(4, 2);
    try std.testing.expectEqual(@as(usize, 2), state.input.view_start);
    state.input_sel_rows[0] = .{ .y = 10, .start = 0, .end = 4, .x = 0 };
    state.input_sel_rows[1] = .{ .y = 11, .start = 4, .end = 8, .x = 0 };
    state.input_sel_row_count = 2;
    state.sel_area = .input;

    // 顶边：上方还有更早的行 → 向上
    state.input.view_start = 1;
    state.drag_y = 9;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, -1), state.auto_scroll_dir);

    // 顶边但视口已在最上 → 不启动
    state.input.view_start = 0;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, 0), state.auto_scroll_dir);

    // 底边：视口下方还有更晚的行 → 向下回滚
    state.drag_y = 11;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, 1), state.auto_scroll_dir);

    // 底边但视口就在底部 → 不启动
    state.input.view_start = 2;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, 0), state.auto_scroll_dir);

    // 停止拖动后清除
    state.sel_dragging = true;
    state.input.view_start = 1;
    state.drag_y = 9;
    state.updateAutoScrollDir();
    try std.testing.expectEqual(@as(i8, -1), state.auto_scroll_dir);
    state.stopDragging();
    try std.testing.expectEqual(@as(i8, 0), state.auto_scroll_dir);
}

test "旧工具输出折叠：批量触发、全文保留、重启后请求体一致" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const alloc = std.testing.allocator;
    const db_path = "skynet_test_fold.db";
    const wal_path = "skynet_test_fold.db-wal";
    const shm_path = "skynet_test_fold.db-shm";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, wal_path) catch {};
    Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, wal_path) catch {};
        Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    }

    var live = AppState{};
    live.io = io;
    live.allocator = alloc;
    live.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (live.db) |*d| d.deinit();
    const sid = try live.db.?.createSession("");
    live.session_id = sid;
    defer {
        for (live.history.items) |m| freeMessage(alloc, m);
        live.history.deinit(alloc);
        for (live.messages.items) |m| live.freeDisplayMessage(m);
        live.messages.deinit(alloc);
    }

    _ = live.persistMessage(.{ .role = "system", .content = system_prompt });
    live.appendHistory("system", system_prompt);
    _ = live.persistMessage(.{ .role = "user", .content = "开始" });
    live.appendHistory("user", "开始");

    // 三条 100KB 工具输出：保护窗口 160KB → 最旧的 1 条应被折叠
    const call_ids = [_][]const u8{ "call_1", "call_2", "call_3" };
    const tool_names = [_][]const u8{ "read", "grep", "bash" };
    const calls = [_]ai.ToolCall{
        .{ .id = "call_1", .name = "read", .arguments = "{}" },
        .{ .id = "call_2", .name = "grep", .arguments = "{}" },
        .{ .id = "call_3", .name = "bash", .arguments = "{\"command\":\"echo hi\"}" },
    };
    const calls_json = try toolCallsToJson(alloc, &calls);
    defer alloc.free(calls_json);
    _ = live.persistMessage(.{ .role = "assistant", .content = "调用工具", .tool_calls = calls_json });
    live.appendHistoryMessage(.{ .role = "assistant", .content = "调用工具", .tool_calls = &calls });

    var tool_contents: [3][]u8 = undefined;
    for (&tool_contents, 0..) |*p, i| {
        const c = try alloc.alloc(u8, 100_000);
        @memset(c, @intCast('a' + i));
        if (i == 2) {
            // bash 输出按行分布（块渲染只保留前 20 行）
            for (c, 0..) |*b, idx| {
                if (idx % 100 == 99) b.* = '\n';
            }
        }
        p.* = c;
    }
    defer for (tool_contents) |c| alloc.free(c);
    for (tool_contents, 0..) |c, i| {
        const id = live.persistMessage(.{ .role = "tool", .content = c, .tool_call_id = call_ids[i], .tool_name = tool_names[i] });
        live.appendHistoryMessage(.{ .role = "tool", .content = c, .tool_call_id = call_ids[i], .db_id = id });
    }

    // 再追加两个空的用户回合：工具输出进入「最近 2 回合」之外才可折叠
    for (0..2) |i| {
        var ub: [16]u8 = undefined;
        const utext = std.fmt.bufPrint(&ub, "继续{d}", .{i}) catch unreachable;
        _ = live.persistMessage(.{ .role = "user", .content = utext });
        live.appendHistory("user", utext);
    }

    // 设置 usage 锚点（模拟上一轮真实 usage）：折叠后锚点 token 应递减
    live.context_usage = .{ .input_tokens = 200_000, .output_tokens = 1_000, .cached_tokens = 190_000 };
    live.usage_anchor_tokens = 201_000;
    live.usage_anchor_len = live.history.items.len;

    // 批量折叠：只折最旧的一条（最新 160KB 受保护，且达到 80KB 触发阈值）
    const folded = live.maybeFoldOldToolOutputs();
    try std.testing.expectEqual(@as(usize, 1), folded);
    // 锚点递减：100000 字节 ≈ 25000 tokens
    try std.testing.expectEqual(@as(u64, 201_000 - 25_000), live.usage_anchor_tokens);

    const h = live.history.items;
    try std.testing.expectEqual(@as(usize, 8), h.len);
    // 最旧一条：content 变成 stub，且带上工具名
    try std.testing.expect(std.mem.startsWith(u8, h[3].content, fold_marker));
    try std.testing.expect(std.mem.indexOf(u8, h[3].content, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, h[3].content, "100000") != null);
    // 较新的两条保持完整
    try std.testing.expectEqual(@as(usize, 100_000), h[4].content.len);
    try std.testing.expectEqual(@as(usize, 100_000), h[5].content.len);

    // 再跑一次不重复折叠（已无可折叠候选）
    try std.testing.expectEqual(@as(usize, 0), live.maybeFoldOldToolOutputs());

    // DB：全文进 tool_full，content 是 stub
    const rows = try live.db.?.loadMessages(sid);
    var full_rows: usize = 0;
    for (rows) |r| {
        if (std.mem.eql(u8, r.role, "tool") and r.tool_full.len > 0) {
            full_rows += 1;
            try std.testing.expectEqual(@as(usize, 100_000), r.tool_full.len);
            try std.testing.expect(std.mem.startsWith(u8, r.content, fold_marker));
        }
    }
    try std.testing.expectEqual(@as(usize, 1), full_rows);

    // 重启：从 DB 重建的历史与实时历史生成的请求体逐字节一致（折叠后前缀仍稳定）
    var reloaded = AppState{};
    reloaded.io = io;
    reloaded.allocator = alloc;
    reloaded.session_id = sid;
    defer {
        for (reloaded.history.items) |m| freeMessage(alloc, m);
        reloaded.history.deinit(alloc);
        for (reloaded.messages.items) |m| reloaded.freeDisplayMessage(m);
        reloaded.messages.deinit(alloc);
    }
    reloaded.applyLoadedMessages(rows);

    var schemas: [tools_mod.tool_defs.len]ai.ToolSchema = undefined;
    for (tools_mod.tool_defs, 0..) |d, i| {
        schemas[i] = .{ .name = d.name, .description = d.description, .parameters = d.parameters };
    }
    const body_live = try ai.buildRequestBody(alloc, "m", live.history.items, &schemas, live.sessionUuid(), .{});
    defer alloc.free(body_live);
    const body_reload = try ai.buildRequestBody(alloc, "m", reloaded.history.items, &schemas, reloaded.sessionUuid(), .{});
    defer alloc.free(body_reload);
    try std.testing.expectEqualStrings(body_live, body_reload);
    // 折叠确实生效：请求体里只有 stub，整体显著变小
    try std.testing.expect(std.mem.indexOf(u8, body_live, fold_marker) != null);
    try std.testing.expect(body_live.len < 250_000);

    // 重启后的 UI：bash 块用 tool_full 重建（不是 stub）
    var found_bash_block = false;
    for (reloaded.messages.items) |m| {
        if (m.tool_block == .shell) {
            found_bash_block = true;
            try std.testing.expect(std.mem.startsWith(u8, m.content, "$ echo hi"));
            try std.testing.expect(std.mem.indexOf(u8, m.content, fold_marker) == null);
        }
    }
    try std.testing.expect(found_bash_block);
}

test "外部写入增量刷新：追加新消息且不重复" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const alloc = std.testing.allocator;
    const db_path = "skynet_test_external.db";
    const wal_path = "skynet_test_external.db-wal";
    const shm_path = "skynet_test_external.db-shm";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, wal_path) catch {};
    Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, wal_path) catch {};
        Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    }

    var state = AppState{};
    state.io = io;
    state.allocator = alloc;
    state.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (state.db) |*d| d.deinit();
    defer {
        for (state.history.items) |m| freeMessage(alloc, m);
        state.history.deinit(alloc);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(alloc);
    }

    const sid = try state.db.?.createSession("t");
    state.session_id = sid;
    state.last_seen_msg_id = try state.db.?.insertMessage(.{ .session_id = sid, .role = "system", .content = system_prompt });
    state.appendHistory("system", system_prompt);

    // 外部进程（第二条连接）写入 user + assistant
    {
        var other = try db_mod.Db.openFile(alloc, io, db_path);
        defer other.deinit();
        _ = try other.insertMessage(.{ .session_id = sid, .role = "user", .content = "外部消息" });
        _ = try other.insertMessage(.{ .session_id = sid, .role = "assistant", .content = "外部回复" });
    }

    state.last_db_poll_ms = 0; // 跳过轮询节流
    state.pollExternalUpdates();
    try std.testing.expectEqual(@as(usize, 3), state.history.items.len);
    try std.testing.expectEqualStrings("外部消息", state.history.items[1].content);
    try std.testing.expectEqualStrings("外部回复", state.history.items[2].content);
    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len); // 用户 + AI 显示消息

    // 再次轮询：data_version 未变 → 不重复追加
    state.last_db_poll_ms = 0;
    state.pollExternalUpdates();
    try std.testing.expectEqual(@as(usize, 3), state.history.items.len);

    // 又有外部写入 → 只追加新增的那条
    {
        var other = try db_mod.Db.openFile(alloc, io, db_path);
        defer other.deinit();
        _ = try other.insertMessage(.{ .session_id = sid, .role = "user", .content = "第二条" });
    }
    state.last_db_poll_ms = 0;
    state.pollExternalUpdates();
    try std.testing.expectEqual(@as(usize, 4), state.history.items.len);
    try std.testing.expectEqualStrings("第二条", state.history.items[3].content);
}

test "集成：compaction（需本地 mock 服务器 127.0.0.1:18125）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    std.Io.Dir.cwd().access(io, "test/mock_18125.running", .{}) catch return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const db_path = "skynet_test_compact.db";
    const wal_path = "skynet_test_compact.db-wal";
    const shm_path = "skynet_test_compact.db-shm";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, wal_path) catch {};
    Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, wal_path) catch {};
        Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    }

    var state = AppState{};
    state.io = io;
    state.allocator = alloc;
    state.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (state.db) |*d| d.deinit();
    defer {
        state.config.deinit(alloc);
        for (state.history.items) |m| freeMessage(alloc, m);
        state.history.deinit(alloc);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(alloc);
        state.compact_buf.deinit(alloc);
    }

    _ = state.config.appendProvider(alloc, .{
        .name = "mock",
        .endpoint = "http://127.0.0.1:18125/v1",
    });
    state.config.setCurrentProvider(alloc, "mock");
    state.config.setCurrentModel(alloc, "mock-model");

    const db = &state.db.?;
    const sid = try db.createSession("");
    state.session_id = sid;

    // 构造：system + 可压缩区（user/assistant/tool）+ 最后一条 user（保留区）
    _ = state.persistMessage(.{ .role = "system", .content = system_prompt });
    state.appendHistory("system", system_prompt);
    const uid1 = state.persistMessage(.{ .role = "user", .content = "OLD_MARKER 用户问题一" });
    state.appendHistoryMessage(.{ .role = "user", .content = "OLD_MARKER 用户问题一", .db_id = uid1 });
    const aid1 = state.persistMessage(.{ .role = "assistant", .content = "OLD_MARKER 回答一" });
    state.appendHistoryMessage(.{ .role = "assistant", .content = "OLD_MARKER 回答一", .db_id = aid1 });
    const tid1 = state.persistMessage(.{
        .role = "tool",
        .content = "OLD_MARKER 工具输出",
        .tool_call_id = "c1",
        .tool_name = "read",
    });
    state.appendHistoryMessage(.{ .role = "tool", .content = "OLD_MARKER 工具输出", .tool_call_id = "c1", .db_id = tid1 });
    const uid2 = state.persistMessage(.{ .role = "user", .content = "最后的问题" });
    state.appendHistoryMessage(.{ .role = "user", .content = "最后的问题", .db_id = uid2 });

    state.keep_recent_tokens = 1; // 保留窗口极小：只保留最后一个 user 及其后
    const out = state.runCompaction(0);
    if (out.err) |e| {
        std.debug.print("[compact] err={s}\n", .{e});
    }
    try std.testing.expect(out.compacted);
    try std.testing.expect(out.summarized_messages >= 3);

    const cp = (try db.latestCompaction(sid)).?;
    try std.testing.expect(cp.summary_message_id != 0);
    // 摘要作为 role='summary' 的消息行入库
    var summary_row: ?db_mod.MessageRow = null;
    for (try db.loadMessages(sid)) |r| {
        if (r.id == cp.summary_message_id) summary_row = r;
    }
    try std.testing.expect(summary_row != null);
    try std.testing.expectEqualStrings("summary", summary_row.?.role);
    try std.testing.expect(std.mem.indexOf(u8, summary_row.?.content, "MOCK_SUMMARY") != null);

    // 重建后历史 = system + checkpoint + 保留区（user 开头）
    try std.testing.expectEqual(@as(usize, 3), state.history.items.len);
    try std.testing.expectEqualStrings("system", state.history.items[0].role);
    try std.testing.expect(isCheckpointMessage(state.history.items[1]));
    try std.testing.expectEqualStrings("user", state.history.items[2].role);
    try std.testing.expectEqualStrings("最后的问题", state.history.items[2].content);
    try std.testing.expectEqual(cp.id, state.last_compaction_id);

    // 压缩后的请求体：包含 checkpoint，不再包含被压缩区内容
    var schemas: [tools_mod.tool_defs.len]ai.ToolSchema = undefined;
    for (tools_mod.tool_defs, 0..) |d, i| {
        schemas[i] = .{ .name = d.name, .description = d.description, .parameters = d.parameters };
    }
    const body = try ai.buildRequestBody(alloc, "m", state.history.items, &schemas, state.sessionUuid(), .{});
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "<conversation-checkpoint>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "MOCK_SUMMARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "OLD_MARKER") == null);

    // 显示仍保留全部消息（含被压缩区）；边界有黄标题 + 摘要正文两条
    var display_has_old = false;
    var header_idx: ?usize = null;
    for (state.messages.items, 0..) |m, i| {
        if (std.mem.indexOf(u8, m.content, "OLD_MARKER") != null) display_has_old = true;
        if (std.mem.indexOf(u8, m.content, "▣ 上下文已压缩") != null) header_idx = i;
    }
    try std.testing.expect(display_has_old);
    try std.testing.expect(header_idx != null);
    try std.testing.expect(header_idx.? + 1 < state.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[header_idx.? + 1].content, "MOCK_SUMMARY") != null);

    // 保留区内没有可压缩内容 → 再次压缩为空操作
    const out2 = state.runCompaction(0);
    try std.testing.expect(!out2.compacted);
    try std.testing.expect(out2.err == null);
}

test "中途压缩：工具循环中压缩整段历史（含当前回合，需 mock 18125）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    std.Io.Dir.cwd().access(io, "test/mock_18125.running", .{}) catch return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const db_path: [:0]const u8 = "skynet_test_midcompact.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_midcompact.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_midcompact.db-shm") catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_midcompact.db-wal") catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_midcompact.db-shm") catch {};
    }

    var state = AppState{};
    state.io = io;
    state.allocator = alloc;
    state.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (state.db) |*d| d.deinit();
    defer state.config.deinit(alloc);
    const sid = try state.db.?.createSession("");
    state.session_id = sid;

    const job = try alloc.create(StreamJob);
    defer {
        job.arena.deinit();
        alloc.destroy(job);
    }
    job.* = .{
        .app = &state,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .io = io,
        .cwd = ".",
        .model = "mock-model",
        .endpoint = "http://127.0.0.1:18125/v1",
        .api_key = "x",
        .provider_name = "mock",
        .db_path = db_path,
        .session_id_num = sid,
        .history = &.{},
        .auto_compact_pct = 50,
        .context_window = 500,
        .keep_recent_tokens = 1100, // keep_bytes = 4400：收下 t2(2000)+a2(2036)，t1 超预算
    };
    const arena = job.arena.allocator();

    // 全部消息均已实时落库（模拟 worker 边产出边写库）：
    // 旧回合 sys/u0/a0 + 当前回合 u1/a1/t1/a2/t2
    const Turn = struct {
        fn u(arena2: Allocator, st: *AppState, text: []const u8) !ai.Message {
            const txt = try arena2.dupe(u8, text);
            const row = st.persistMessage(.{ .role = "user", .content = txt });
            return .{ .role = "user", .content = txt, .db_id = row };
        }
        fn a(arena2: Allocator, st: *AppState, text: []const u8, call_id: []const u8) !ai.Message {
            const txt = try arena2.dupe(u8, text);
            const calls = if (call_id.len > 0)
                try cloneToolCalls(arena2, &[_]ai.ToolCall{.{ .id = try arena2.dupe(u8, call_id), .name = "read", .arguments = "{}" }})
            else
                null;
            var calls_json: []const u8 = "";
            var buf: ?[]u8 = null;
            defer if (buf) |b| alloc.free(b);
            if (calls) |cs| {
                buf = try toolCallsToJson(alloc, cs);
                calls_json = buf.?;
            }
            const row = st.persistMessage(.{ .role = "assistant", .content = txt, .tool_calls = calls_json });
            return .{ .role = "assistant", .content = txt, .tool_calls = calls, .db_id = row };
        }
        fn t(arena2: Allocator, st: *AppState, text: []const u8, call_id: []const u8) !ai.Message {
            const c = try arena2.dupe(u8, text);
            const cid = try arena2.dupe(u8, call_id);
            const row = st.persistMessage(.{ .role = "tool", .content = c, .tool_call_id = cid, .tool_name = "read" });
            return .{ .role = "tool", .content = c, .tool_call_id = cid, .db_id = row };
        }
    };

    var hist = std.ArrayListUnmanaged(ai.Message){ .items = &.{}, .capacity = 0 };
    const sys_row = state.persistMessage(.{ .role = "system", .content = system_prompt });
    try hist.append(arena, .{ .role = "system", .content = try arena.dupe(u8, system_prompt), .db_id = sys_row });
    const old_u = "uuuu" ** 500;
    const old_a = "aaaa" ** 500;
    try hist.append(arena, try Turn.u(arena, &state, old_u));
    try hist.append(arena, try Turn.a(arena, &state, old_a, ""));
    const cur_u = "vvvv" ** 125;
    const a1 = "bbbb" ** 500;
    const t1 = "cccc" ** 500;
    const a2 = "dddd" ** 500;
    const t2 = "eeee" ** 500;
    try hist.append(arena, try Turn.u(arena, &state, cur_u)); // 当前回合 user
    try hist.append(arena, try Turn.a(arena, &state, a1, "c1"));
    try hist.append(arena, try Turn.t(arena, &state, t1, "c1"));
    try hist.append(arena, try Turn.a(arena, &state, a2, "c2"));
    try hist.append(arena, try Turn.t(arena, &state, t2, "c2"));
    job.history = try hist.toOwnedSlice(arena);

    // 设置旧锚点：压缩后应失效
    job.anchor_len = 2;
    job.anchor_tokens = 999;

    // 触发中途压缩（keep_bytes=3000：收下 t2(2000)，a2 超预算 → 保留区以 assistant 开头）
    const did = compactJobHistory(job, &state.db.?);
    try std.testing.expect(did);
    try std.testing.expect(job.compacted_midturn);

    // history = system + checkpoint + [a2, t2]：当前回合前半段（u1/a1/t1）进摘要
    try std.testing.expectEqual(@as(usize, 4), job.history.len);
    try std.testing.expectEqualStrings("system", job.history[0].role);
    try std.testing.expect(isCheckpointMessage(job.history[1]));
    try std.testing.expectEqualStrings(a2, job.history[2].content);
    try std.testing.expectEqualStrings(t2, job.history[3].content);
    try std.testing.expect(job.history[2].db_id != 0);
    // 锚点失效（旧锚点对应压缩前的前缀）
    try std.testing.expectEqual(@as(usize, 0), job.anchor_len);
    try std.testing.expectEqual(@as(u64, 0), job.anchor_tokens);

    // checkpoint：摘要入库且 tail 指向保留区首条（a2 的行 id）
    const cp = (try state.db.?.latestCompaction(sid)).?;
    try std.testing.expect(cp.summary_message_id != 0);
    try std.testing.expectEqual(job.history[2].db_id, cp.tail_start_id);
    // 摘要文本覆盖当前回合前半段（payload 含 u1/a1）——mock 返回固定 MOCK_SUMMARY
    var mid_summary_ok = false;
    for (try state.db.?.loadMessages(sid)) |r| {
        if (r.id == cp.summary_message_id and std.mem.indexOf(u8, r.content, "MOCK_SUMMARY") != null) {
            mid_summary_ok = true;
        }
    }
    try std.testing.expect(mid_summary_ok);

    // 重启视角：按 checkpoint 重建的历史 = system + checkpoint + [a2,t2]
    var reloaded = AppState{};
    reloaded.io = io;
    reloaded.allocator = alloc;
    reloaded.session_id = sid;
    defer {
        for (reloaded.history.items) |m| freeMessage(alloc, m);
        reloaded.history.deinit(alloc);
        for (reloaded.messages.items) |m| reloaded.freeDisplayMessage(m);
        reloaded.messages.deinit(alloc);
    }
    const rows = try state.db.?.loadMessages(sid);
    reloaded.applyLoadedMessagesWithCheckpoint(rows, cp, true);
    try std.testing.expectEqual(@as(usize, 4), reloaded.history.items.len);
    try std.testing.expectEqualStrings("assistant", reloaded.history.items[2].role);
    try std.testing.expectEqualStrings(a2, reloaded.history.items[2].content);
    try std.testing.expectEqualStrings(t2, reloaded.history.items[3].content);

    // 再压一次：保留区（a2,t2）之后没有可压缩内容 → 不再触发
    try std.testing.expect(!compactJobHistory(job, &state.db.?));
}

test "实时落库：persistTranscriptEntry 写入 DB 并回填 db_id（幂等）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();
    const alloc = std.testing.allocator;

    const db_path: [:0]const u8 = "skynet_test_eager.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_eager.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_eager.db-shm") catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_eager.db-wal") catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_eager.db-shm") catch {};
    }

    var state = AppState{};
    state.io = io;
    state.allocator = alloc;
    state.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (state.db) |*d| d.deinit();
    const sid = try state.db.?.createSession("");
    state.session_id = sid;

    const job = try alloc.create(StreamJob);
    defer {
        job.arena.deinit();
        alloc.destroy(job);
    }
    job.* = .{
        .app = &state,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .io = io,
        .cwd = ".",
        .model = "m",
        .endpoint = "",
        .api_key = "",
        .provider_name = "p",
        .db_path = db_path,
        .session_id_num = sid,
        .history = &.{},
    };
    const arena = job.arena.allocator();

    // assistant：带工具调用 + 思考 + 单轮用量
    const calls = try cloneToolCalls(arena, &[_]ai.ToolCall{.{ .id = "call_9", .name = "bash", .arguments = "{\"command\":\"echo hi\"}" }});
    var hist = std.ArrayListUnmanaged(ai.Message){ .items = &.{}, .capacity = 0 };
    try hist.append(arena, .{ .role = "assistant", .content = try arena.dupe(u8, "先跑一下"), .tool_calls = calls });
    job.history = try hist.toOwnedSlice(arena);
    try job.transcript.append(arena, .{
        .msg = job.history[0],
        .reasoning = try arena.dupe(u8, "想一想"),
        .reasoning_ms = 42,
        .usage = .{ .input_tokens = 100, .output_tokens = 7, .cached_tokens = 88 },
    });

    persistTranscriptEntry(job, &state.db.?, 0, 0);
    const aid = job.transcript.items[0].msg.db_id;
    try std.testing.expect(aid != 0);
    try std.testing.expectEqual(aid, job.history[0].db_id); // 历史副本同步回填

    const rows = try state.db.?.loadMessages(sid);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("assistant", rows[0].role);
    try std.testing.expectEqualStrings("先跑一下", rows[0].content);
    try std.testing.expectEqualStrings("想一想", rows[0].reasoning);
    try std.testing.expectEqual(@as(i64, 42), rows[0].reasoning_ms);
    try std.testing.expectEqual(@as(i64, 100), rows[0].input_tokens);
    try std.testing.expectEqual(@as(i64, 88), rows[0].cached_tokens);
    try std.testing.expectEqual(@as(i64, 7), rows[0].output_tokens);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].tool_calls, "call_9") != null);

    // 幂等：已有 db_id 时不重复写入
    persistTranscriptEntry(job, &state.db.?, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), (try state.db.?.loadMessages(sid)).len);

    // tool 结果：渲染元数据（tool_name / is_error）随行落库
    try job.tool_meta.append(arena, .{ .id = "call_9", .name = "bash", .display = "", .is_error = true });
    var hist2 = std.ArrayListUnmanaged(ai.Message){ .items = &.{}, .capacity = 0 };
    try hist2.appendSlice(arena, job.history);
    try hist2.append(arena, .{ .role = "tool", .content = try arena.dupe(u8, "boom"), .tool_call_id = try arena.dupe(u8, "call_9") });
    job.history = try hist2.toOwnedSlice(arena);
    try job.transcript.append(arena, .{ .msg = job.history[1] });
    persistTranscriptEntry(job, &state.db.?, 1, 1);
    try std.testing.expect(job.history[1].db_id != 0);

    var saw_tool = false;
    for (try state.db.?.loadMessages(sid)) |r| {
        if (std.mem.eql(u8, r.role, "tool")) {
            saw_tool = true;
            try std.testing.expectEqualStrings("bash", r.tool_name);
            try std.testing.expectEqual(@as(i64, 1), r.is_error);
            try std.testing.expectEqualStrings("call_9", r.tool_call_id);
        }
    }
    try std.testing.expect(saw_tool);

    // 会话 id 为 0（无法落库）：worker 不开连接，db_id 保持 0 → 回退 finalize 批量落库
    var slot: ?db_mod.Db = null;
    job.session_id_num = 0;
    try std.testing.expect(ensureWorkerDb(job, &slot) == null);
    try std.testing.expect(slot == null);
    job.session_id_num = sid;
    try std.testing.expect(ensureWorkerDb(job, &slot) != null);
    if (slot) |*d| d.deinit();
}

test "手动压缩：小会话自适应缩小保留窗口（需 mock 18125）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    std.Io.Dir.cwd().access(io, "test/mock_18125.running", .{}) catch return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const db_path = "skynet_test_adaptive.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_adaptive.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_adaptive.db-shm") catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_adaptive.db-wal") catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_adaptive.db-shm") catch {};
    }

    var state = AppState{};
    state.io = io;
    state.allocator = alloc;
    state.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (state.db) |*d| d.deinit();
    defer {
        state.config.deinit(alloc);
        for (state.history.items) |m| freeMessage(alloc, m);
        state.history.deinit(alloc);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(alloc);
        state.compact_buf.deinit(alloc);
    }

    _ = state.config.appendProvider(alloc, .{
        .name = "mock",
        .endpoint = "http://127.0.0.1:18125/v1",
    });
    state.config.setCurrentProvider(alloc, "mock");
    state.config.setCurrentModel(alloc, "mock-model");

    const sid = try state.db.?.createSession("");
    state.session_id = sid;
    _ = state.persistMessage(.{ .role = "system", .content = system_prompt });
    const f0 = "F0" ** 4000;
    const r1 = state.persistMessage(.{ .role = "user", .content = f0 });
    _ = r1;
    const f1 = "F1" ** 4000;
    _ = state.persistMessage(.{ .role = "assistant", .content = f1 });
    const f2 = "F2" ** 4000;
    _ = state.persistMessage(.{ .role = "user", .content = f2 });
    const f3 = "F3" ** 4000;
    _ = state.persistMessage(.{ .role = "assistant", .content = f3 });

    state.loadSessionContent(sid);
    try std.testing.expect((try state.db.?.latestCompaction(sid)) == null);

    // 默认保留 20k 对小会话无内容可压 → 自适应缩小后应压缩成功（异步流式路径）
    state.runCompactCommand(0);
    var guard: usize = 0;
    while (state.compact_status.load(.acquire) != 0 and guard < 1000) : (guard += 1) {
        state.pumpCompaction();
        Io.sleep(io, Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u8, 0), state.compact_status.load(.acquire));
    try std.testing.expect((try state.db.?.latestCompaction(sid)) != null);

    // 流式摘要：完成提示（含"以上 N 条"）+ 正文含 MOCK_SUMMARY
    var head_idx: ?usize = null;
    for (state.messages.items, 0..) |m, i| {
        if (std.mem.indexOf(u8, m.content, "上下文已压缩") != null) head_idx = i;
    }
    try std.testing.expect(head_idx != null);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[head_idx.?].content, "以上") != null);
    try std.testing.expect(head_idx.? + 1 < state.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[head_idx.? + 1].content, "MOCK_SUMMARY") != null);
}

test "历史往返一致：落库重读后的请求体与实时逐字节相同" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const db_path = "skynet_test_roundtrip.db";
    const wal_path = "skynet_test_roundtrip.db-wal";
    const shm_path = "skynet_test_roundtrip.db-shm";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, wal_path) catch {};
    Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, wal_path) catch {};
        Io.Dir.cwd().deleteFile(io, shm_path) catch {};
    }

    var db = try db_mod.Db.openFile(std.testing.allocator, io, db_path);
    defer db.deinit();
    const sid = try db.createSession("");

    // ── 实时状态：按 finalizeStream 的成对路径（insertMessage + appendHistoryMessage）──
    var live = AppState{};
    live.io = io;
    live.allocator = std.testing.allocator;
    live.session_id = sid;
    defer {
        for (live.history.items) |m| freeMessage(std.testing.allocator, m);
        live.history.deinit(std.testing.allocator);
        for (live.messages.items) |m| live.freeDisplayMessage(m);
        live.messages.deinit(std.testing.allocator);
    }

    _ = try db.insertMessage(.{ .session_id = sid, .role = "system", .content = system_prompt });
    live.appendHistory("system", system_prompt);

    // user：前后空格、tab、行尾空格
    const user_text = " 看下 a b\tc  ";
    _ = try db.insertMessage(.{ .session_id = sid, .role = "user", .content = user_text });
    live.appendHistory("user", user_text);

    // assistant + tool_calls（arguments 含空格/转义/中文）
    const calls = [_]ai.ToolCall{.{
        .id = "call_1",
        .name = "read",
        .arguments = "{\"path\": \"src/a b.zig\", \"note\": \"含 \\\"引号\\\"  和空格\"}",
    }};
    const calls_json = try toolCallsToJson(std.testing.allocator, &calls);
    defer std.testing.allocator.free(calls_json);
    const asst_text = "读一下 \n\n 这个文件。";
    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "assistant",
        .content = asst_text,
        .tool_calls = calls_json,
        .reasoning = "思考内容只落库不进历史",
        .reasoning_ms = 123,
    });
    live.appendHistoryMessage(.{ .role = "assistant", .content = asst_text, .tool_calls = &calls });

    // tool：非法 UTF-8（GBK 字节）+ CRLF + 行尾空格 + 末尾换行
    const tool_text = "输出开头\r\n行尾空格   \nGBK:\xB7\xA1 结束\n";
    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "tool",
        .content = tool_text,
        .tool_call_id = "call_1",
        .tool_name = "read",
    });
    live.appendHistoryMessage(.{ .role = "tool", .content = tool_text, .tool_call_id = "call_1" });

    // 纯工具调用轮：正文与思考均为空（工具循环中的常见形状）。
    // 两条路径都必须把它以 content="" 入历史（序列化为 "content": null），
    // 否则请求体出现差异会让该轮之后的缓存全部失效
    const calls2 = [_]ai.ToolCall{.{
        .id = "call_2",
        .name = "bash",
        .arguments = "{\"command\":\"echo hi\"}",
    }};
    const calls2_json = try toolCallsToJson(std.testing.allocator, &calls2);
    defer std.testing.allocator.free(calls2_json);
    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "assistant",
        .content = "",
        .tool_calls = calls2_json,
    });
    live.appendHistoryMessage(.{ .role = "assistant", .content = "", .tool_calls = &calls2 });

    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "tool",
        .content = "hi\n",
        .tool_call_id = "call_2",
        .tool_name = "bash",
    });
    live.appendHistoryMessage(.{ .role = "tool", .content = "hi\n", .tool_call_id = "call_2" });

    // 第二个 user
    _ = try db.insertMessage(.{ .session_id = sid, .role = "user", .content = "继续" });
    live.appendHistory("user", "继续");

    // ── 重读：全新状态从 DB 恢复 ──
    var reloaded = AppState{};
    reloaded.io = io;
    reloaded.allocator = std.testing.allocator;
    reloaded.session_id = sid;
    defer {
        for (reloaded.history.items) |m| freeMessage(std.testing.allocator, m);
        reloaded.history.deinit(std.testing.allocator);
        for (reloaded.messages.items) |m| reloaded.freeDisplayMessage(m);
        reloaded.messages.deinit(std.testing.allocator);
    }
    reloaded.applyLoadedMessages(try db.loadMessages(sid));

    try std.testing.expectEqual(live.history.items.len, reloaded.history.items.len);

    // 空正文纯工具调用轮必须保留在历史里（而非被丢弃），且形态一致
    var empty_round_live = false;
    var empty_round_reload = false;
    for (live.history.items) |m| {
        if (std.mem.eql(u8, m.role, "assistant") and m.content.len == 0 and m.tool_calls != null) empty_round_live = true;
    }
    for (reloaded.history.items) |m| {
        if (std.mem.eql(u8, m.role, "assistant") and m.content.len == 0 and m.tool_calls != null) empty_round_reload = true;
    }
    try std.testing.expect(empty_round_live);
    try std.testing.expect(empty_round_reload);

    // 会话路由标识确定性一致（跨重启缓存亲和的前提）
    try std.testing.expectEqualStrings(live.sessionUuid(), reloaded.sessionUuid());

    // 请求体逐字节相同（含 tool_calls、工具输出清洗结果）
    var schemas: [tools_mod.tool_defs.len]ai.ToolSchema = undefined;
    for (tools_mod.tool_defs, 0..) |d, i| {
        schemas[i] = .{ .name = d.name, .description = d.description, .parameters = d.parameters };
    }
    const live_body = try ai.buildRequestBody(std.testing.allocator, "m", live.history.items, &schemas, live.sessionUuid(), .{
        .cache_key = true,
        .retention = .short,
    });
    defer std.testing.allocator.free(live_body);
    const reload_body = try ai.buildRequestBody(std.testing.allocator, "m", reloaded.history.items, &schemas, reloaded.sessionUuid(), .{
        .cache_key = true,
        .retention = .short,
    });
    defer std.testing.allocator.free(reload_body);
    try std.testing.expectEqualStrings(live_body, reload_body);
}

test "思考强度：选单、设置与候选" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        state.config.deinit(std.testing.allocator);
    }

    // 候选随模型变化：flash 支持 low
    try std.testing.expectEqual(@as(usize, 4), thinkingLevelsFor("deepseek-v4.1-flash").len);
    try std.testing.expectEqual(@as(usize, 3), thinkingLevelsFor("deepseek-v4-pro").len);
    try std.testing.expect(isThinkingLevel("max") and isThinkingLevel("low"));
    try std.testing.expect(!isThinkingLevel("bogus"));

    // 选单：从帮助菜单进入，光标定位到当前值；Esc 返回
    state.config.setThinking(std.testing.allocator, "max");
    state.config.setCurrentModel(std.testing.allocator, "deepseek-v4.1-flash");
    state.openThinkingSelect(.help_select);
    try std.testing.expectEqual(Mode.thinking_select, state.mode);
    try std.testing.expectEqual(@as(usize, 3), state.thinking_select_index); // off/low/high/max → max 在下标 3
    state.handleThinkingSelectKey(.{ .code = .esc });
    try std.testing.expectEqual(Mode.help_select, state.mode);

    // 应用（不落盘）：右上角悬浮通知，不往聊天区刷消息
    state.applyThinking("high", false);
    try std.testing.expectEqualStrings("high", state.config.thinking);
    try std.testing.expect(state.messages.items.len == 0);
    try std.testing.expect(std.mem.indexOf(u8, state.toast[0..state.toast_len], "思考强度: high") != null);
}

test "思考块 auto（硬编码）：思考时展开，正文开始时折叠" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    // 思考开始：自动展开（流式显示）
    state.appendStreamReasoning("先想一想");
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expect(state.messages.items[0].reasoning_expanded);

    // 用户中途手动折叠再展开：不影响随后的自动折叠
    toggleThought(&state, 0);
    try std.testing.expect(!state.messages.items[0].reasoning_expanded);
    toggleThought(&state, 0);
    try std.testing.expect(state.messages.items[0].reasoning_expanded);

    // 正文开始：思考结束 → 折叠（即使中途手动展开过）
    state.appendStreamChunk("正文来了");
    try std.testing.expect(!state.messages.items[0].reasoning_expanded);

    // 折叠发生在思考结束时，此后手动展开保持不被夺回
    toggleThought(&state, 0);
    try std.testing.expect(state.messages.items[0].reasoning_expanded);
    state.appendStreamChunk("更多正文");
    try std.testing.expect(state.messages.items[0].reasoning_expanded);
}

test "思考块 auto（硬编码）：工具轮（无正文）在回合结束时折叠" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    // 只有思考、没有正文的工具轮：思考中保持展开
    state.appendStreamReasoning("先看看文件");
    try std.testing.expect(state.messages.items[0].reasoning_expanded);

    // 回合结束（turn_end / 工具阶段开始）：自动折叠
    state.closeCurrentTurn();
    try std.testing.expect(!state.messages.items[0].reasoning_expanded);

    // 工具块追加不影响折叠状态
    try std.testing.expect(state.beginToolBlock("bash", "{\"command\":\"echo hi\"}", .shell));
    try std.testing.expect(state.appendToolBlockBody(.shell, "hi", false));
    try std.testing.expect(!state.messages.items[0].reasoning_expanded);

    // 最终回答只有思考（无正文）时，收尾也要折叠
    state.appendStreamReasoning("收尾思考");
    try std.testing.expect(state.messages.items[2].reasoning_expanded);
    state.finalizeStream(null);
    try std.testing.expect(!state.messages.items[2].reasoning_expanded);
}

test "重启恢复：纯工具调用轮不产生空消息（工具间隔为一行）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    state.message_wrap_width = 60;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
    }

    // 真实序列：思考+read 轮 / 纯工具调用轮（无正文无思考）+edit / 纯工具调用轮+bash
    const rows = [_]db_mod.MessageRow{
        .{ .id = 1, .role = "user", .content = "改代码" },
        .{ .id = 2, .role = "assistant", .content = "", .reasoning = "先看看", .reasoning_ms = 800, .tool_calls = "[{\"id\":\"c1\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}]" },
        .{ .id = 3, .role = "tool", .content = "file body", .tool_call_id = "c1", .tool_name = "read" },
        .{ .id = 4, .role = "assistant", .content = "", .tool_calls = "[{\"id\":\"c2\",\"name\":\"edit\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}]" },
        .{ .id = 5, .role = "tool", .content = "Successfully replaced 1 block(s)", .tool_call_id = "c2", .tool_name = "edit", .tool_display = "  1 - old\n  1 + new" },
        .{ .id = 6, .role = "assistant", .content = "", .tool_calls = "[{\"id\":\"c3\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"zig build\\\"}\"}]" },
        .{ .id = 7, .role = "tool", .content = "ok\n", .tool_call_id = "c3", .tool_name = "bash" },
    };
    state.applyLoadedMessagesWithCheckpoint(&rows, null, true);

    // 恢复出的显示消息：user / 思考 / read行 / edit块 / bash块（无空消息）
    try std.testing.expectEqual(@as(usize, 5), state.messages.items.len);
    for (state.messages.items) |m| {
        try std.testing.expect(m.content.len > 0 or m.reasoning != null);
        try std.testing.expect(messageRowCount(m, 60) > 0);
    }
    try std.testing.expect(state.messages.items[1].reasoning != null);
    try std.testing.expectEqual(ToolBlockKind.diff, state.messages.items[3].tool_block.?);
    try std.testing.expectEqual(ToolBlockKind.shell, state.messages.items[4].tool_block.?);

    // 渲染：Read 行与 Edit 块之间、Edit 与 bash 块之间恰好各一个空行
    var buf = try tui.render.Buffer.init(std.testing.allocator, 60, 24);
    defer buf.deinit();
    drawMessages(&state, .{ .x = 0, .y = 0, .width = 60, .height = 24 }, &buf);

    // 布局：r0 用户 / r1 空 / r2 Thought头 / r3 空 / r4 Read行 / r5 空 /
    //       r6 Edit头 / r7-r8 diff / r9 空 / r10 bash头 / r11 输出
    try std.testing.expectEqual(@as(u21, 'T'), buf.get(2, 2).?.char); // "> Thought"
    try std.testing.expectEqual(@as(u21, 'R'), buf.get(3, 4).?.char); // "→ Read"（→ 占 2 列）
    try std.testing.expectEqual(@as(u21, '←'), buf.get(0, 6).?.char); // "← Edit"
    try std.testing.expectEqual(@as(u21, '$'), buf.get(0, 10).?.char); // "$ zig build"
    for ([_]u16{ 1, 3, 5, 9 }) |blank_y| {
        for (0..60) |x| {
            const cell = buf.get(@intCast(x), blank_y).?;
            try std.testing.expect(cell.char == ' ' or cell.char == 0);
        }
    }
}

test "思考块间距：无正文时不多留空行（与消息间隔不叠加成两行）" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    state.message_wrap_width = 40;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    const reason = try std.testing.allocator.dupe(u8, "想一想");
    // 只有思考（工具轮的 assistant 消息）：折叠 = 头 1 行，不留正文空行
    try state.messages.append(std.testing.allocator, .{ .content = "", .style = .{}, .reasoning = reason });
    try std.testing.expectEqual(@as(usize, 1), messageRowCount(state.messages.items[0], 40));

    // 展开：头 1 + 空行 1 + 思考 1 行（仍不留正文空行）
    state.messages.items[0].reasoning_expanded = true;
    try std.testing.expectEqual(@as(usize, 3), messageRowCount(state.messages.items[0], 40));
    state.messages.items[0].reasoning_expanded = false;

    // 渲染：思考头 → 空行 1 → 工具块标题（旧实现这里会多出第二个空行）
    try std.testing.expect(state.beginToolBlock("bash", "{\"command\":\"echo hi\"}", .shell));

    var buf = try tui.render.Buffer.init(std.testing.allocator, 40, 4);
    defer buf.deinit();
    drawMessages(&state, .{ .x = 0, .y = 0, .width = 40, .height = 4 }, &buf);

    // 行 0："> Thought: ..."；行 1：空行；行 2：工具块标题 "$ echo hi"
    try std.testing.expectEqual(@as(u21, 'T'), buf.get(2, 0).?.char);
    for (0..40) |x| {
        const cell = buf.get(@intCast(x), 1).?;
        try std.testing.expect(cell.char == ' ' or cell.char == 0);
    }
    try std.testing.expectEqual(@as(u21, '$'), buf.get(0, 2).?.char);

    // 思考 + 正文：头 1 + 正文前空行 1 + 正文 1
    const r2 = try std.testing.allocator.dupe(u8, "想一想");
    const c2 = try std.testing.allocator.dupe(u8, "正文");
    try state.messages.append(std.testing.allocator, .{ .content = c2, .style = .{}, .reasoning = r2 });
    try std.testing.expectEqual(@as(usize, 3), messageRowCount(state.messages.items[2], 40));

    // 布局：思考头 r0 / 空行 r1 / 工具块 r2 / 空行 r3 / 思考头 r4 / 空行 r5 / 正文 r6
    var buf2 = try tui.render.Buffer.init(std.testing.allocator, 40, 8);
    defer buf2.deinit();
    drawMessages(&state, .{ .x = 0, .y = 0, .width = 40, .height = 8 }, &buf2);
    try std.testing.expectEqual(@as(u21, 'T'), buf2.get(2, 4).?.char);
    for (0..40) |x| {
        const cell = buf2.get(@intCast(x), 5).?;
        try std.testing.expect(cell.char == ' ' or cell.char == 0);
    }
    try std.testing.expectEqual(@as(u21, '正'), buf2.get(0, 6).?.char);
}

test "usage 锚点：估算 = 真实 usage + 其后增量；历史重建后失效" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
    }

    try std.testing.expect(state.usage_anchor_len == null);
    state.appendHistory("system", "sys");
    state.appendHistory("user", "第一问");

    // 无锚点：纯估算（会低估中文密集内容）
    const pure = state.estimateRequestTokens();

    // 模拟一轮真实 usage（服务端计数）后设置锚点
    state.context_usage = .{ .input_tokens = 20_000, .output_tokens = 500, .cached_tokens = 19_000 };
    state.usage_anchor_tokens = 20_500;
    state.usage_anchor_len = state.history.items.len;

    // 锚定估算 = 20500 + 新增消息的估算增量
    state.appendHistory("user", "x" ** 400); // 400B ≈ 100 tokens
    const anchored = state.estimateRequestTokens();
    try std.testing.expectEqual(@as(usize, 20_500 + 100), anchored);
    try std.testing.expect(anchored > pure);

    // 变量变化：任意新增消息只按增量估算，锚点不变
    state.appendHistory("assistant", "y" ** 40); // 40B = 10 tokens
    try std.testing.expectEqual(@as(usize, 20_500 + 100 + 10), state.estimateRequestTokens());

    // 历史重建（clearHistory / 加载 / 新建会话）→ 锚点失效，回退纯估算
    state.clearHistory();
    try std.testing.expect(state.usage_anchor_len == null);
    try std.testing.expectEqual(@as(u64, 0), state.usage_anchor_tokens);

    // refreshEstimatedUsage 同样清空锚点（估算值不再是真实前缀的代表）
    state.usage_anchor_len = 3;
    state.usage_anchor_tokens = 12_345;
    state.refreshEstimatedUsage();
    try std.testing.expect(state.usage_anchor_len == null);

    // worker 侧：job 锚点优先于纯估算（工具循环中途压缩的阈值判定）
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var dummy_state = AppState{};
    dummy_state.allocator = std.testing.allocator;
    var msgs = [_]ai.Message{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "x" ** 400 },
    };
    var job = StreamJob{
        .app = &dummy_state,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .io = io,
        .cwd = ".",
        .model = "m",
        .endpoint = "",
        .api_key = "",
        .provider_name = "p",
        .history = &msgs,
        .anchor_len = 1,
        .anchor_tokens = 5_000,
    };
    defer job.arena.deinit();
    try std.testing.expectEqual(@as(usize, 5_100), estimateJobRequestTokens(&job));

    // 锚点越界（历史被截断）→ 回退纯估算（不为 5100+）
    job.anchor_len = 5;
    try std.testing.expect(estimateJobRequestTokens(&job) != 5_100);
}

test "usage 锚点：只认正常结束的回合，取消不设锚点" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
    }

    state.appendHistory("system", "sys");
    state.appendHistory("user", "问");

    const mkJob = struct {
        fn create(st: *AppState) *StreamJob {
            const job = st.allocator.create(StreamJob) catch unreachable;
            job.* = .{
                .app = st,
                .arena = std.heap.ArenaAllocator.init(st.allocator),
                .io = st.io,
                .cwd = ".",
                .model = "m",
                .endpoint = "",
                .api_key = "",
                .provider_name = "p",
                .history = st.history.items,
            };
            // 模拟此前至少成功过一轮：round_usage 有真实值
            job.round_usage = .{ .input_tokens = 20_000, .output_tokens = 500 };
            return job;
        }
    };

    // 取消的回合：不设锚点（history 含部分内容，旧 usage 不能代表前缀）
    state.stream_job = mkJob.create(&state);
    state.setStreamStatus(.canceled);
    state.finalizeStream(null);
    try std.testing.expect(state.usage_anchor_len == null);
    try std.testing.expectEqual(@as(u64, 0), state.usage_anchor_tokens);

    // 正常结束的回合：设置锚点
    state.stream_job = mkJob.create(&state);
    state.setStreamStatus(.done);
    state.finalizeStream(null);
    try std.testing.expect(state.usage_anchor_len != null);
    try std.testing.expectEqual(@as(u64, 20_500), state.usage_anchor_tokens);
}

test "模糊宽度档位解析：显式 wide/narrow，其余一律 auto" {
    try std.testing.expectEqual(AmbiguousMode.wide, parseAmbiguousMode("wide"));
    try std.testing.expectEqual(AmbiguousMode.narrow, parseAmbiguousMode("narrow"));
    try std.testing.expectEqual(AmbiguousMode.auto, parseAmbiguousMode(""));
    try std.testing.expectEqual(AmbiguousMode.auto, parseAmbiguousMode("auto"));
    try std.testing.expectEqual(AmbiguousMode.auto, parseAmbiguousMode("bogus"));
}

test "模糊宽度应用：auto = 窄基底 + 推荐名单；wide/narrow 为纯档" {
    const allocator = std.testing.allocator;
    var state = AppState{};
    state.allocator = allocator;
    defer state.config.deinit(allocator);
    // 恢复渲染层默认（.wide + 空覆盖名单），避免影响其他测试的坐标断言
    defer tui.render.width_mod.ambiguous_width = .wide;
    defer tui.render.width_mod.setWidthOverrides(&[_]u21{}, &[_]u21{});

    // 默认（config 未配置）＝ auto：窄基底 + 推荐名单定向加宽
    try std.testing.expectEqualStrings("", state.config.ambiguous_width);
    applyAmbiguousWidth(&state);
    try std.testing.expectEqual(tui.render.width_mod.AmbiguousWidth.narrow, tui.render.width_mod.ambiguous_width);
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('①')); // 推荐名单
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('⑤'));
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth(0x24EA)); // ⓪ 同族一并加宽
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth(0x24B6)); // Ⓐ
    try std.testing.expectEqual(@as(u2, 1), tui.render.codepointWidth('—')); // 其余 A 类保持窄
    try std.testing.expectEqual(@as(u2, 1), tui.render.codepointWidth('→'));
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('中')); // 真宽不受影响

    // 用户 narrow 覆盖优先于推荐名单（① 放回窄，名单其余字符仍宽）
    state.config.setWidthOverridesNarrow(allocator, "①");
    applyAmbiguousWidth(&state);
    try std.testing.expectEqual(@as(u2, 1), tui.render.codepointWidth('①'));
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('②'));
    state.config.setWidthOverridesNarrow(allocator, "");

    // narrow = 纯窄（不叠加推荐名单）
    state.config.setAmbiguousWidth(allocator, "narrow");
    applyAmbiguousWidth(&state);
    try std.testing.expectEqual(@as(u2, 1), tui.render.codepointWidth('①'));

    // wide = 纯全宽（A 类全部 2 列，无需名单）
    state.config.setAmbiguousWidth(allocator, "wide");
    applyAmbiguousWidth(&state);
    try std.testing.expectEqual(tui.render.width_mod.AmbiguousWidth.wide, tui.render.width_mod.ambiguous_width);
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('①'));
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('—'));
}

test "宽度覆盖名单：解析（范围/单点/字面/非法 token）" {
    const alloc = std.testing.allocator;
    var list: std.ArrayListUnmanaged(u21) = .{ .items = &.{}, .capacity = 0 };
    defer list.deinit(alloc);

    parseWidthOverrides(alloc, "U+2460-U+2462", &list);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x2460, 0x2461, 0x2462 }, list.items);
    list.clearRetainingCapacity();

    // 逗号分隔、小写 u+、U+ 前缀可省的区间上界
    parseWidthOverrides(alloc, "U+2460, u+24EA U+24EB-24EC", &list);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x2460, 0x24EA, 0x24EB, 0x24EC }, list.items);
    list.clearRetainingCapacity();

    // 字面字符（每个字符分别计入）
    parseWidthOverrides(alloc, "— → ①ab", &list);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x2014, 0x2192, 0x2460, 'a', 'b' }, list.items);
    list.clearRetainingCapacity();

    // 非法 token 跳过，不影响合法部分
    parseWidthOverrides(alloc, "U+ZZZ U+2460-U+ ①", &list);
    try std.testing.expectEqualSlices(u21, &[_]u21{0x2460}, list.items);
}

test "宽度覆盖应用：覆盖优先于策略，真宽字符不被 narrow 收缩" {
    const alloc = std.testing.allocator;
    var state = AppState{};
    state.allocator = alloc;
    defer state.config.deinit(alloc);
    defer tui.render.width_mod.ambiguous_width = .wide;
    defer tui.render.width_mod.setWidthOverrides(&[_]u21{}, &[_]u21{});

    // 用户的偏好档：基础策略 narrow + 带圈数字覆盖为 wide + — 覆盖为 narrow
    state.config.setAmbiguousWidth(alloc, "narrow");
    state.config.setWidthOverridesWide(alloc, "U+2460-U+2462");
    state.config.setWidthOverridesNarrow(alloc, "— 中");
    applyAmbiguousWidth(&state);

    try std.testing.expectEqual(tui.render.width_mod.AmbiguousWidth.narrow, tui.render.width_mod.ambiguous_width);
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('①')); // 覆盖为宽
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('③'));
    try std.testing.expectEqual(@as(u2, 1), tui.render.codepointWidth('④')); // 未覆盖 + narrow 策略
    try std.testing.expectEqual(@as(u2, 1), tui.render.codepointWidth('—'));
    try std.testing.expectEqual(@as(u2, 2), tui.render.codepointWidth('中')); // 真宽不被收缩
}

test "压缩确认框：菜单进入两关确认" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    // 菜单选 compact → 打开确认框（默认停在"否"）
    state.executeHelpCommand("compact");
    try std.testing.expectEqual(Mode.compact_confirm, state.mode);
    try std.testing.expectEqual(@as(u8, 1), state.confirm_stage);
    try std.testing.expect(!state.confirm_yes);

    // 第一关选"否" → 返回主界面，不执行
    state.handleCompactConfirmKey(.{ .code = .enter });
    try std.testing.expectEqual(Mode.normal, state.mode);
    try std.testing.expectEqual(@as(u8, 0), state.confirm_stage);

    // 再进确认框：两关都选"是" → 执行压缩（无 provider 时安全报错）
    state.executeHelpCommand("compact");
    state.confirm_yes = true;
    state.handleCompactConfirmKey(.{ .code = .enter });
    try std.testing.expectEqual(@as(u8, 2), state.confirm_stage);
    try std.testing.expect(!state.confirm_yes); // 第二关重新默认"否"
    state.confirm_yes = true;
    state.handleCompactConfirmKey(.{ .code = .enter });
    try std.testing.expectEqual(Mode.normal, state.mode);
    try std.testing.expectEqual(@as(u8, 0), state.confirm_stage);

    var found = false;
    for (state.messages.items) |m| {
        if (std.mem.indexOf(u8, m.content, "无可用提供商") != null) found = true;
    }
    try std.testing.expect(found);
}

test "上下文估算：加载会话后即有占用（无需先对话）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const alloc = std.testing.allocator;
    const db_path = "skynet_test_estimate.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_estimate.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, "skynet_test_estimate.db-shm") catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_estimate.db-wal") catch {};
        Io.Dir.cwd().deleteFile(io, "skynet_test_estimate.db-shm") catch {};
    }

    var state = AppState{};
    state.io = io;
    state.allocator = alloc;
    state.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (state.db) |*d| d.deinit();
    defer {
        for (state.history.items) |m| freeMessage(alloc, m);
        state.history.deinit(alloc);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(alloc);
        state.compact_buf.deinit(alloc);
    }

    // 新会话（加载路径）即有非零估算，且标记为估算、无缓存数据
    state.newSession();
    try std.testing.expect(state.last_usage.input_tokens > 0);
    try std.testing.expectEqual(state.last_usage.input_tokens, state.context_usage.input_tokens);
    try std.testing.expect(state.usage_estimated);
    try std.testing.expectEqual(@as(u64, 0), state.last_usage.cached_tokens);

    // 真实 usage 到来后不再是估算
    state.last_usage = .{ .input_tokens = 500, .cached_tokens = 400, .output_tokens = 20 };
    state.usage_estimated = false;
    try std.testing.expect(!state.usage_estimated);

    // 重新加载会话 → 回到估算值（切换/重载场景）
    const sid = state.session_id;
    state.loadSessionContent(sid);
    try std.testing.expect(state.usage_estimated);
    try std.testing.expect(state.last_usage.input_tokens > 0);
}

test "会话路由标识：按会话 id 确定性派生" {
    var a = AppState{};
    a.session_id = 42;
    const id_a = a.sessionUuid();
    var a_again = AppState{};
    a_again.session_id = 42;
    try std.testing.expectEqualStrings(id_a, a_again.sessionUuid());

    var b = AppState{};
    b.session_id = 43;
    try std.testing.expect(!std.mem.eql(u8, id_a, b.sessionUuid()));

    // UUID 形态（8-4-4-4-12）
    try std.testing.expectEqual(@as(usize, 36), id_a.len);
    try std.testing.expectEqual(@as(u8, '-'), id_a[8]);
    try std.testing.expectEqual(@as(u8, '-'), id_a[13]);
    try std.testing.expectEqual(@as(u8, '-'), id_a[18]);
    try std.testing.expectEqual(@as(u8, '-'), id_a[23]);
}

// ══════════════════════════════════════════════════════════════════════
// 独立验证（不属于原实现作者）：针对 tool_full / 折叠策略的对抗性测试
// ══════════════════════════════════════════════════════════════════════

/// 按实时路径模拟“用户回合 + 助手发起单个工具调用 + 返回结果”的回合：
/// 落库（拿 db_id）+ 进内存历史，与 finalizeStream 的成对流程一致。
fn verifyAppendToolRound(alloc: Allocator, st: *AppState, uid: usize, name: []const u8, args: []const u8, content: []const u8) !void {
    var ub: [16]u8 = undefined;
    const utext = try std.fmt.bufPrint(&ub, "继续{d}", .{uid});
    _ = st.persistMessage(.{ .role = "user", .content = utext });
    st.appendHistory("user", utext);
    const id_str = try std.fmt.allocPrint(alloc, "call_{d}", .{uid});
    defer alloc.free(id_str);
    const calls = [_]ai.ToolCall{.{ .id = id_str, .name = name, .arguments = args }};
    const calls_json = try toolCallsToJson(alloc, &calls);
    defer alloc.free(calls_json);
    _ = st.persistMessage(.{ .role = "assistant", .content = "", .tool_calls = calls_json });
    st.appendHistoryMessage(.{ .role = "assistant", .content = "", .tool_calls = &calls });
    const row_id = st.persistMessage(.{ .role = "tool", .content = content, .tool_call_id = id_str, .tool_name = name });
    st.appendHistoryMessage(.{ .role = "tool", .content = content, .tool_call_id = id_str, .db_id = row_id });
}

test "独立验证：折叠阈值边界与保护窗口（批量）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();
    const alloc = std.testing.allocator;

    const Scenario = struct { sizes: []const usize, want_folded: usize };
    // sizes 按“最旧→最新”排列；每条都是 50KB 级真实量级（tools 里 cap 约 50KB）
    const scenarios = [_]Scenario{
        .{ .sizes = &.{ fold_min_bytes - 1, 200_000 }, .want_folded = 0 }, // 差 1 字节不触发
        .{ .sizes = &.{ fold_min_bytes, 200_000 }, .want_folded = 1 }, // 正好达阈值触发
        .{ .sizes = &.{ 100_000, 100_000, 100_000, 100_000 }, .want_folded = 2 }, // 保护最近 160KB
        .{ .sizes = &.{ 50_000, 50_000, 50_000, 50_000 }, .want_folded = 0 }, // 全在窗口内
        .{ .sizes = &.{ 50_000, 50_000, 50_000, 50_000, 50_000 }, .want_folded = 0 }, // 窗口外仅 50KB
        .{ .sizes = &.{ 50_000, 50_000, 50_000, 50_000, 50_000, 50_000 }, .want_folded = 2 }, // 窗口外 100KB
    };

    for (scenarios, 0..) |sc, si| {
        var path_buf: [64]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&path_buf, "skynet_verify_fold_{d}.db", .{si});
        var wal_buf: [80]u8 = undefined;
        const wal_path = try std.fmt.bufPrintZ(&wal_buf, "{s}-wal", .{db_path});
        var shm_buf: [80]u8 = undefined;
        const shm_path = try std.fmt.bufPrintZ(&shm_buf, "{s}-shm", .{db_path});
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, wal_path) catch {};
        Io.Dir.cwd().deleteFile(io, shm_path) catch {};
        defer {
            Io.Dir.cwd().deleteFile(io, db_path) catch {};
            Io.Dir.cwd().deleteFile(io, wal_path) catch {};
            Io.Dir.cwd().deleteFile(io, shm_path) catch {};
        }

        var st = AppState{};
        st.io = io;
        st.allocator = alloc;
        st.db = try db_mod.Db.openFile(alloc, io, db_path);
        defer if (st.db) |*d| d.deinit();
        const sid = try st.db.?.createSession("");
        st.session_id = sid;
        defer {
            for (st.history.items) |m| freeMessage(alloc, m);
            st.history.deinit(alloc);
            for (st.messages.items) |m| st.freeDisplayMessage(m);
            st.messages.deinit(alloc);
        }

        _ = st.persistMessage(.{ .role = "system", .content = system_prompt });
        st.appendHistory("system", system_prompt);
        _ = st.persistMessage(.{ .role = "user", .content = "开始" });
        st.appendHistory("user", "开始");

        const n = sc.sizes.len;
        const calls = try alloc.alloc(ai.ToolCall, n);
        defer alloc.free(calls);
        const ids = try alloc.alloc([]u8, n);
        defer {
            for (ids) |id| alloc.free(id);
            alloc.free(ids);
        }
        for (0..n) |i| {
            ids[i] = try std.fmt.allocPrint(alloc, "call_{d}", .{i});
            calls[i] = .{ .id = ids[i], .name = "read", .arguments = "{}" };
        }
        const calls_json = try toolCallsToJson(alloc, calls);
        defer alloc.free(calls_json);
        _ = st.persistMessage(.{ .role = "assistant", .content = "批量读取", .tool_calls = calls_json });
        st.appendHistoryMessage(.{ .role = "assistant", .content = "批量读取", .tool_calls = calls });

        for (sc.sizes, 0..) |sz, i| {
            const c = try alloc.alloc(u8, sz);
            defer alloc.free(c);
            @memset(c, 'x');
            const id = st.persistMessage(.{ .role = "tool", .content = c, .tool_call_id = ids[i], .tool_name = "read" });
            st.appendHistoryMessage(.{ .role = "tool", .content = c, .tool_call_id = ids[i], .db_id = id });
        }

        // 再追加两个空的用户回合：工具输出进入「最近 2 回合」之外才可折叠
        for (0..2) |i| {
            var ub: [16]u8 = undefined;
            const utext = try std.fmt.bufPrint(&ub, "继续{d}", .{i});
            _ = st.persistMessage(.{ .role = "user", .content = utext });
            st.appendHistory("user", utext);
        }

        const folded = st.maybeFoldOldToolOutputs();
        try std.testing.expectEqual(sc.want_folded, folded);

        // 折叠的必须是“最旧的 want_folded 条”；其余保持原长、原内容
        var idx: usize = 0;
        for (st.history.items) |m| {
            if (!std.mem.eql(u8, m.role, "tool")) continue;
            if (idx < sc.want_folded) {
                try std.testing.expect(std.mem.startsWith(u8, m.content, fold_marker));
            } else {
                try std.testing.expect(!std.mem.startsWith(u8, m.content, fold_marker));
                try std.testing.expectEqual(sc.sizes[idx], m.content.len);
            }
            idx += 1;
        }
        try std.testing.expectEqual(n, idx);

        // 折叠过的行：DB.content = stub，DB.tool_full = 全文
        const rows = try st.db.?.loadMessages(sid);
        var db_folded: usize = 0;
        for (rows) |r| {
            if (std.mem.eql(u8, r.role, "tool") and r.tool_full.len > 0) {
                db_folded += 1;
                try std.testing.expect(std.mem.startsWith(u8, r.content, fold_marker));
            }
        }
        try std.testing.expectEqual(sc.want_folded, db_folded);
    }
}

test "独立验证：tool_full 不被二次折叠覆盖，db_id 不进请求体" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();
    const alloc = std.testing.allocator;

    var db = try db_mod.Db.openFile(alloc, io, ":memory:");
    defer db.deinit();
    const sid = try db.createSession("");

    const full = "原始工具全文\n第二行内容";
    const id = try db.insertMessage(.{ .session_id = sid, .role = "tool", .content = full, .tool_call_id = "c1", .tool_name = "read" });
    try db.foldToolMessage(id, "STUB-A", full);
    // 再次折叠（不同内容）不得覆盖首次结果（WHERE tool_full = '' 守卫）
    try db.foldToolMessage(id, "STUB-B", "被改写");
    const rows = try db.loadMessages(sid);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("STUB-A", rows[0].content);
    try std.testing.expectEqualStrings(full, rows[0].tool_full);

    // db_id 仅为本地字段，不参与序列化
    const msgs = [_]ai.Message{.{ .role = "tool", .content = "x", .tool_call_id = "c1", .db_id = 987654321 }};
    const body = try ai.buildRequestBody(alloc, "m", &msgs, &.{}, "sess", .{ .cache_key = true });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "db_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "987654321") == null);
}

test "独立验证：重启后块工具用全文重建、大小统计按原文、多轮折叠前缀稳定" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();
    const alloc = std.testing.allocator;

    const db_path = "skynet_verify_display.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, db_path ++ "-wal") catch {};
    Io.Dir.cwd().deleteFile(io, db_path ++ "-shm") catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, db_path ++ "-wal") catch {};
        Io.Dir.cwd().deleteFile(io, db_path ++ "-shm") catch {};
    }

    var live = AppState{};
    live.io = io;
    live.allocator = alloc;
    live.db = try db_mod.Db.openFile(alloc, io, db_path);
    defer if (live.db) |*d| d.deinit();
    const sid = try live.db.?.createSession("");
    live.session_id = sid;
    defer {
        for (live.history.items) |m| freeMessage(alloc, m);
        live.history.deinit(alloc);
        for (live.messages.items) |m| live.freeDisplayMessage(m);
        live.messages.deinit(alloc);
    }

    _ = live.persistMessage(.{ .role = "system", .content = system_prompt });
    live.appendHistory("system", system_prompt);
    _ = live.persistMessage(.{ .role = "user", .content = "开始" });
    live.appendHistory("user", "开始");

    // read 输出 50000 字节（非块工具；重启后大小统计应显示 48.8KB）
    const read_buf = try alloc.alloc(u8, 50_000);
    defer alloc.free(read_buf);
    @memset(read_buf, 'r');

    // bash 输出：10 行、含标记（块工具；重启后应看到 BASH_MARKER 全文而非 stub）
    var bash_out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer bash_out.deinit(alloc);
    var pad: [4900]u8 = undefined;
    @memset(&pad, 'b');
    for (0..10) |li| {
        if (li == 0) {
            try bash_out.appendSlice(alloc, "BASH_MARKER head\n");
        } else {
            try bash_out.appendSlice(alloc, "BASH_MARKER ");
            try bash_out.appendSlice(alloc, &pad);
            try bash_out.append(alloc, '\n');
        }
    }

    // 回合 0：read（最旧，将被折叠）；回合 1：bash（次旧，将被折叠）
    try verifyAppendToolRound(alloc, &live, 0, "read", "{}", read_buf);
    try verifyAppendToolRound(alloc, &live, 1, "bash", "{\"command\":\"echo hi\"}", bash_out.items);
    // 回合 2..7：再 6 条 read，凑满 8 个回合（最近 2 回合受位置保护）
    for (2..8) |i| {
        try verifyAppendToolRound(alloc, &live, i, "read", "{}", read_buf);
    }

    // 第一次折叠：最近 2 回合受保护 + 保护窗口 160KB → 最旧的 2 条（read、bash）折叠
    try std.testing.expectEqual(@as(usize, 2), live.maybeFoldOldToolOutputs());

    var first_stub: []const u8 = "";
    for (live.history.items) |m| {
        if (std.mem.eql(u8, m.tool_call_id orelse "", "call_0")) first_stub = m.content;
    }
    try std.testing.expect(std.mem.startsWith(u8, first_stub, fold_marker));
    const first_stub_copy = try alloc.dupe(u8, first_stub);
    defer alloc.free(first_stub_copy);

    // 多轮：追加两个回合把更早的两条推出保护窗口，应折最旧的 2 条（call_2、call_3），旧 stub 逐字节不变
    try verifyAppendToolRound(alloc, &live, 8, "read", "{}", read_buf);
    try verifyAppendToolRound(alloc, &live, 9, "read", "{}", read_buf);
    try std.testing.expectEqual(@as(usize, 2), live.maybeFoldOldToolOutputs());
    for (live.history.items) |m| {
        if (std.mem.eql(u8, m.tool_call_id orelse "", "call_0")) {
            try std.testing.expectEqualStrings(first_stub_copy, m.content);
        }
    }
    // 第三次：已无可折叠候选（幂等）
    try std.testing.expectEqual(@as(usize, 0), live.maybeFoldOldToolOutputs());

    // 重启：从 DB 重建
    const rows = try live.db.?.loadMessages(sid);
    var reloaded = AppState{};
    reloaded.io = io;
    reloaded.allocator = alloc;
    reloaded.session_id = sid;
    defer {
        for (reloaded.history.items) |m| freeMessage(alloc, m);
        reloaded.history.deinit(alloc);
        for (reloaded.messages.items) |m| reloaded.freeDisplayMessage(m);
        reloaded.messages.deinit(alloc);
    }
    reloaded.applyLoadedMessages(rows);

    var schemas: [tools_mod.tool_defs.len]ai.ToolSchema = undefined;
    for (tools_mod.tool_defs, 0..) |d, i| {
        schemas[i] = .{ .name = d.name, .description = d.description, .parameters = d.parameters };
    }
    const live_body = try ai.buildRequestBody(alloc, "m", live.history.items, &schemas, live.sessionUuid(), .{ .cache_key = true, .retention = .short });
    defer alloc.free(live_body);
    const reload_body = try ai.buildRequestBody(alloc, "m", reloaded.history.items, &schemas, reloaded.sessionUuid(), .{ .cache_key = true, .retention = .short });
    defer alloc.free(reload_body);
    try std.testing.expectEqualStrings(live_body, reload_body);
    try std.testing.expect(std.mem.indexOf(u8, live_body, fold_marker) != null);

    // UI：块工具（bash）用 tool_full 全文重建，非块工具（read）大小统计按原文
    var bash_full_seen = false;
    var read_size_seen = false;
    for (reloaded.messages.items) |m| {
        if (m.tool_block == .shell) {
            bash_full_seen = true;
            try std.testing.expect(std.mem.indexOf(u8, m.content, "BASH_MARKER") != null);
            try std.testing.expect(std.mem.indexOf(u8, m.content, fold_marker) == null);
        }
        if (std.mem.indexOf(u8, m.content, "(48.8KB)") != null) read_size_seen = true;
    }
    try std.testing.expect(bash_full_seen);
    try std.testing.expect(read_size_seen);
}

test "预设选择器：选定后表单预填（含 env 名）" {
    var state = AppState{};
    state.allocator = std.testing.allocator;

    state.startProviderAdd();
    try std.testing.expectEqual(Mode.preset_select, state.mode);
    try std.testing.expectEqual(@as(usize, 0), state.preset_select_index);

    // 选中 openai 预设（列表第 0 项）
    state.handlePresetSelectKey(.{ .code = .enter });
    try std.testing.expectEqual(Mode.provider_add, state.mode);
    try std.testing.expectEqualStrings("openai", state.providerFormPreset());
    try std.testing.expectEqualStrings("openai", state.provider_form_name.value());
    try std.testing.expectEqualStrings("https://api.openai.com/v1", state.provider_form_url.value());
    try std.testing.expectEqualStrings("OPENAI_API_KEY", state.provider_form_key_env.value());

    // 名称/地址只读：光标直接落在密钥栏，Tab 跳过前两栏
    try std.testing.expect(state.providerFormLocked());
    try std.testing.expectEqual(@as(usize, 2), state.provider_form_field);
    try std.testing.expect(state.provider_form_key.focused);
    state.providerFormNext();
    try std.testing.expectEqual(@as(usize, 3), state.provider_form_field);
    state.providerFormNext();
    try std.testing.expectEqual(@as(usize, 2), state.provider_form_field);
    state.providerFormPrev();
    try std.testing.expectEqual(@as(usize, 3), state.provider_form_field);

    // 末项为自定义：字段全空且从名称开始编辑
    state.startProviderAdd();
    state.preset_select_index = config_mod.presets.len;
    state.handlePresetSelectKey(.{ .code = .enter });
    try std.testing.expectEqualStrings("", state.providerFormPreset());
    try std.testing.expectEqualStrings("", state.provider_form_url.value());
    try std.testing.expect(!state.providerFormLocked());
    try std.testing.expectEqual(@as(usize, 0), state.provider_form_field);
}

test "删除提供商：最近模型引用前移" {
    var recent: [5]RecentEntry = undefined;
    var count: usize = 3;
    recent[0] = .{ .provider = 0, .name = undefined, .len = 0 };
    recent[1] = .{ .provider = 2, .name = undefined, .len = 0 };
    recent[2] = .{ .provider = 3, .name = undefined, .len = 0 };

    // 删除下标 0：第一条移除，其余 -1
    pruneRecentProviderRefs(&recent, &count, 0);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 1), recent[0].provider);
    try std.testing.expectEqual(@as(usize, 2), recent[1].provider);

    // 删除下标 1（原 2）：中间条目移除
    pruneRecentProviderRefs(&recent, &count, 1);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), recent[0].provider);
}

test "提供商删除：Del 打开确认框，两关确认" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    state.message_wrap_width = 40;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }
    _ = state.config.appendProvider(std.testing.allocator, .{ .name = "a", .endpoint = "http://a/v1" });
    _ = state.config.appendProvider(std.testing.allocator, .{ .name = "b", .endpoint = "http://b/v1" });
    defer state.config.deinit(std.testing.allocator);

    // Del 落在第二个提供商 b 上 → 打开确认框（默认停在“否”）
    state.model_select_index = 1;
    state.handleModelSelectKey(.{ .code = .delete });
    try std.testing.expectEqual(Mode.provider_confirm, state.mode);
    try std.testing.expectEqual(@as(u8, 1), state.confirm_stage);
    try std.testing.expectEqual(@as(?usize, 1), state.provider_confirm_index);
    try std.testing.expect(!state.confirm_yes);

    // 第一关选“是” → 进入第二关，仍未删除
    state.confirm_yes = true;
    state.handleProviderConfirmKey(.{ .code = .enter });
    try std.testing.expectEqual(@as(u8, 2), state.confirm_stage);
    try std.testing.expect(!state.confirm_yes);
    try std.testing.expectEqual(@as(usize, 2), state.config.providers.items.len);

    // Esc 取消 → 返回列表且未删除
    state.handleProviderConfirmKey(.{ .code = .esc });
    try std.testing.expectEqual(Mode.model_select, state.mode);
    try std.testing.expectEqual(@as(usize, 2), state.config.providers.items.len);
    try std.testing.expect(state.provider_confirm_index == null);

    // Del 落在“+ 添加提供商…”或最近模型上 → 不弹确认
    state.model_select_index = 2;
    state.handleModelSelectKey(.{ .code = .delete });
    try std.testing.expectEqual(Mode.model_select, state.mode);
}

test "env 回退：api_key 为空时读取环境变量" {
    var state = AppState{};
    state.allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("SKYNET_TEST_KEY", "secret-from-env");
    state.environ_map = &env_map;

    var p = config_mod.Provider{
        .name = @constCast("x"),
        .endpoint = @constCast("https://example.com/v1"),
        .api_key = @constCast(""),
        .api_key_env = @constCast("SKYNET_TEST_KEY"),
    };
    try std.testing.expectEqualStrings("secret-from-env", state.resolvedApiKey(&p));

    // 配置文件里的 key 优先
    p.api_key = @constCast("inline-key");
    try std.testing.expectEqualStrings("inline-key", state.resolvedApiKey(&p));

    // 未设置环境变量 → 空
    p.api_key = @constCast("");
    p.api_key_env = @constCast("SKYNET_NO_SUCH_KEY");
    try std.testing.expectEqualStrings("", state.resolvedApiKey(&p));
}

test "上下文窗口启发式与百分比" {
    try std.testing.expectEqual(@as(u64, 1_048_576), modelContextWindow("deepseek-v4.1-flash"));
    try std.testing.expectEqual(@as(u64, 200_000), modelContextWindow("claude-sonnet-4-5"));
    try std.testing.expectEqual(@as(u64, 1_047_576), modelContextWindow("gpt-4.1-mini"));
    try std.testing.expectEqual(@as(u64, 131_072), modelContextWindow("some-local-model"));

    try std.testing.expectEqual(@as(u64, 0), contextUsagePercent(0, 128_000));
    try std.testing.expectEqual(@as(u64, 50), contextUsagePercent(64_000, 128_000));
    try std.testing.expectEqual(@as(u64, 100), contextUsagePercent(128_000, 128_000));
    try std.testing.expectEqual(@as(u64, 999), contextUsagePercent(1_000_000, 1));

    // 紧凑显示
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("131.0k", formatCount(&b, 131_072));
    try std.testing.expectEqualStrings("1.0M", formatCount(&b, 1_047_576));

    // 缓存命中率百分比
    try std.testing.expectEqual(@as(u64, 0), cacheHitPercent(0, 104_900));
    try std.testing.expectEqual(@as(u64, 0), cacheHitPercent(10, 0));
    try std.testing.expectEqual(@as(u64, 99), cacheHitPercent(104_800, 104_900));
    try std.testing.expectEqual(@as(u64, 100), cacheHitPercent(50_000, 50_000));
    try std.testing.expectEqual(@as(u64, 100), cacheHitPercent(200, 100)); // 防御：不超 100
}

test "状态栏：缓存命中率百分比与着色" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    defer state.config.deinit(std.testing.allocator);

    state.config.setCurrentModel(std.testing.allocator, "deepseek-v4.1-flash");
    state.context_usage = .{ .input_tokens = 104_900, .cached_tokens = 104_800 };

    var buf = try tui.render.Buffer.init(std.testing.allocator, 160, 1);
    defer buf.deinit();
    drawInputStatus(&state, .{ .x = 0, .y = 0, .width = 160, .height = 1 }, &buf);

    var line: [160]u8 = undefined;
    for (0..160) |i| {
        const cell = buf.get(@intCast(i), 0).?;
        line[i] = if (cell.char < 128) @intCast(cell.char) else '?';
    }
    const text = std.mem.trimEnd(u8, &line, " "); // 宽字符已置换为 '?'
    try std.testing.expect(std.mem.endsWith(u8, text, " 104.8k/104.9k 99%"));

    // 高命中率（>=80）：绿色
    const hit_x = std.mem.indexOf(u8, text, "99%").?;
    try std.testing.expect(buf.get(@intCast(hit_x), 0).?.fg.eql(tui.style.Color.green));

    // 中等命中率（>=50）：黄色
    state.context_usage = .{ .input_tokens = 104_900, .cached_tokens = 78_675 };
    var buf2 = try tui.render.Buffer.init(std.testing.allocator, 160, 1);
    defer buf2.deinit();
    drawInputStatus(&state, .{ .x = 0, .y = 0, .width = 160, .height = 1 }, &buf2);
    renderRowText(&buf2, &line);
    const text2 = std.mem.trimEnd(u8, &line, " ");
    try std.testing.expect(std.mem.endsWith(u8, text2, " 78.6k/104.9k 75%"));
    try std.testing.expect(buf2.get(@intCast(std.mem.indexOf(u8, text2, "75%").?), 0).?.fg.eql(tui.style.Color.yellow));

    // 低命中率（<50）：红色
    state.context_usage = .{ .input_tokens = 104_900, .cached_tokens = 20_000 };
    var buf3 = try tui.render.Buffer.init(std.testing.allocator, 160, 1);
    defer buf3.deinit();
    drawInputStatus(&state, .{ .x = 0, .y = 0, .width = 160, .height = 1 }, &buf3);
    renderRowText(&buf3, &line);
    const text3 = std.mem.trimEnd(u8, &line, " ");
    try std.testing.expect(std.mem.endsWith(u8, text3, " 20.0k/104.9k 19%"));
    try std.testing.expect(buf3.get(@intCast(std.mem.indexOf(u8, text3, "19%").?), 0).?.fg.eql(tui.style.Color.red));
}

/// 测试辅助：把一行单元格转成 ASCII 文本（宽字符以 '?' 占位）
fn renderRowText(buf: *tui.render.Buffer, out: *[160]u8) void {
    for (0..buf.width) |i| {
        const cell = buf.get(@intCast(i), 0).?;
        out[i] = if (cell.char < 128) @intCast(cell.char) else '?';
    }
}

test "流式追加消息：上翻阅读时保持视口不动" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    state.message_wrap_width = 40;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    state.addUserMessage("hi");
    try std.testing.expectEqual(@as(usize, 0), state.scroll_offset);

    // 上翻阅读中：新增 1 行内容 + 1 个消息间隔空行 → 偏移 +2，视口原地不动
    state.scroll_offset = 10;
    state.addStreamMessage("→ Read foo.zig", tool_call_style);
    try std.testing.expectEqual(@as(usize, 12), state.scroll_offset);

    // 贴底：继续跟随最新消息
    state.scroll_offset = 0;
    state.addStreamMessage("→ Read bar.zig", tool_call_style);
    try std.testing.expectEqual(@as(usize, 0), state.scroll_offset);

    // 工具块（bash）标题同样保持视口（标题 1 行 + 间隔 1 行）
    state.scroll_offset = 5;
    try std.testing.expect(state.beginToolBlock("bash", "{\"command\":\"echo hi\"}", .shell));
    try std.testing.expectEqual(@as(usize, 7), state.scroll_offset);

    // 多行追加按实际行数 + 间隔补偿
    state.scroll_offset = 3;
    state.addStreamMessage("a\nb\nc", .{});
    try std.testing.expectEqual(@as(usize, 7), state.scroll_offset);
}

test "启动恢复：打开会话即记录访问，重启加载的是它（非最大 id）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const db_path = "skynet_test_lastvisit.db";
    Io.Dir.cwd().deleteFile(io, db_path) catch {};
    Io.Dir.cwd().deleteFile(io, db_path ++ "-wal") catch {};
    Io.Dir.cwd().deleteFile(io, db_path ++ "-shm") catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, db_path) catch {};
        Io.Dir.cwd().deleteFile(io, db_path ++ "-wal") catch {};
        Io.Dir.cwd().deleteFile(io, db_path ++ "-shm") catch {};
    }

    var db = try db_mod.Db.openFile(std.testing.allocator, io, db_path);
    defer db.deinit();

    // A 先建、B 后建（B 的 id 更大且最近发过消息）
    const sid_a = try db.createSession("我上次访问的会话");
    const sid_b = try db.createSession("id 更大但久未用");
    _ = try db.insertMessage(.{ .session_id = sid_b, .role = "user", .content = "很久以前在 B 聊过" });
    try db.sess.exec("UPDATE \"session\" SET last_active_at = 1000 WHERE id = ?", .{sid_a});
    try db.sess.exec("UPDATE \"session\" SET last_active_at = 2000 WHERE id = ?", .{sid_b});

    // 模拟：用户打开了 A（不发言）后退出 → A 被标记为最近访问
    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    state.db = db_mod.Db.openFile(std.testing.allocator, io, db_path) catch null;
    defer {
        if (state.db) |*d| d.deinit();
        for (state.history.items) |m| freeMessage(std.testing.allocator, m);
        state.history.deinit(std.testing.allocator);
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }
    state.loadSessionContent(sid_a);
    try std.testing.expectEqual(sid_a, state.session_id);

    // 模拟重启：latestSession 必须返回 A（旧实现按 id 最大会返回 B）
    const latest = (try db.latestSession()).?;
    try std.testing.expectEqual(sid_a, latest.id);
}

test "空占位的流式消息移除时反向补偿偏移" {
    var state = AppState{};
    state.allocator = std.testing.allocator;
    state.message_wrap_width = 40;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    state.addMessage("已有消息", .{});
    state.scroll_offset = 3;

    // 新建空流式消息：多出间隔空行 → 偏移 +1
    _ = state.ensureStreamingMessage();
    try std.testing.expectEqual(@as(usize, 4), state.scroll_offset);

    // 回合结束时回收空消息 → 偏移 -1，视口原地不动
    state.closeCurrentTurn();
    try std.testing.expectEqual(@as(usize, 3), state.scroll_offset);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
}

test "上翻阅读：工具调用追加消息后端到端视口不变" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var state = AppState{};
    state.io = io;
    state.allocator = std.testing.allocator;
    state.message_wrap_width = 40;
    defer {
        for (state.messages.items) |m| state.freeDisplayMessage(m);
        state.messages.deinit(std.testing.allocator);
    }

    // 10 条历史消息（各 1 行 + 间隔 = 19 行），上翻到中途
    for (0..10) |i| {
        var b: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&b, "历史消息 {d}", .{i}) catch unreachable;
        state.addMessage(text, .{});
    }
    state.scroll_offset = 5;

    var buf = try tui.render.Buffer.init(std.testing.allocator, 40, 10);
    defer buf.deinit();
    drawMessages(&state, .{ .x = 0, .y = 0, .width = 40, .height = 10 }, &buf);
    var row0_before: [160]u8 = undefined;
    renderRowText(&buf, &row0_before);
    const row0_text = std.mem.trimEnd(u8, &row0_before, " ");
    try std.testing.expect(row0_text.len > 0); // 确有内容可比

    // 工具调用行（流式路径）：首行内容必须原地不动
    state.addStreamMessage("→ Read foo.zig", tool_call_style);
    var buf2 = try tui.render.Buffer.init(std.testing.allocator, 40, 10);
    defer buf2.deinit();
    drawMessages(&state, .{ .x = 0, .y = 0, .width = 40, .height = 10 }, &buf2);
    var row0_after: [160]u8 = undefined;
    renderRowText(&buf2, &row0_after);
    try std.testing.expectEqualStrings(row0_text, std.mem.trimEnd(u8, &row0_after, " "));

    // 工具块 + 新一轮思考（ensureStreamingMessage 新建消息）同样不移动
    try std.testing.expect(state.beginToolBlock("bash", "{\"command\":\"zig build\"}", .shell));
    state.appendStreamReasoning("再想想");
    var buf3 = try tui.render.Buffer.init(std.testing.allocator, 40, 10);
    defer buf3.deinit();
    drawMessages(&state, .{ .x = 0, .y = 0, .width = 40, .height = 10 }, &buf3);
    var row0_after2: [160]u8 = undefined;
    renderRowText(&buf3, &row0_after2);
    try std.testing.expectEqualStrings(row0_text, std.mem.trimEnd(u8, &row0_after2, " "));
}
