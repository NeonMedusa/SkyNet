const std = @import("std");
const fr = @import("fridge");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Log = @import("log.zig");

pub const MessageRow = struct {
    id: i64 = 0,
    session_id: i64 = 0,
    role: []const u8 = "",
    content: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    created_at: i64 = 0,
    /// 思考过程（推理模型的 reasoning，可为空）
    reasoning: []const u8 = "",
    /// 思考耗时（毫秒）
    reasoning_ms: i64 = 0,
    /// 助手消息发起的工具调用（JSON 数组文本，可为空）
    tool_calls: []const u8 = "",
    /// 工具结果对应的调用 id（role = "tool" 时）
    tool_call_id: []const u8 = "",
    /// 工具名（role = "tool" 时；用于重启后重建工具块）
    tool_name: []const u8 = "",
    /// 工具块正文（edit 的行号 diff 等；shell 类工具为空，正文即 content）
    tool_display: []const u8 = "",
    /// 折叠前的工具输出全文（content 被折叠成 stub 时非空；供 UI 展示）
    tool_full: []const u8 = "",
    /// 工具是否执行失败（0/1）
    is_error: i64 = 0,
    /// token 用量（assistant 消息；压缩基线与统计用）
    input_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    output_tokens: i64 = 0,
};

/// insertMessage 参数（字段较多，用具名结构）
pub const NewMessage = struct {
    session_id: i64 = 0,
    role: []const u8,
    content: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    reasoning: []const u8 = "",
    reasoning_ms: i64 = 0,
    tool_calls: []const u8 = "",
    tool_call_id: []const u8 = "",
    /// 工具名（role = "tool" 时）
    tool_name: []const u8 = "",
    /// 工具块渲染正文（edit diff 等）
    tool_display: []const u8 = "",
    /// 折叠前的工具输出全文（可为空）
    tool_full: []const u8 = "",
    /// 工具是否执行失败（0/1）
    is_error: i64 = 0,
    /// token 用量（assistant 消息；压缩基线与统计用）
    input_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    output_tokens: i64 = 0,
};

pub const SessionInfo = struct {
    id: i64 = 0,
    title: []const u8 = "",
    created_at: i64 = 0,
    last_active_at: i64 = 0,
};

pub const SessionListRow = struct {
    id: i64 = 0,
    title: []const u8 = "",
    created_at: i64 = 0,
    last_active_at: i64 = 0,
    msg_count: i64 = 0,
};

/// 压缩 checkpoint：summary 之前的消息不再进入模型上下文
pub const CompactionRow = struct {
    id: i64 = 0,
    session_id: i64 = 0,
    created_at: i64 = 0,
    /// 摘要正文（summary_message_id 为 0 的旧记录使用；新记录以消息行为准）
    summary: []const u8 = "",
    /// 摘要消息行 id（role='summary'；0 = 旧记录，回退到 summary 字段）
    summary_message_id: i64 = 0,
    /// 保留区起始消息 id（含）：id >= tail_start_id 的消息仍完整发送
    tail_start_id: i64 = 0,
    /// 压缩前的估算 token（展示用）
    tokens_before: i64 = 0,
    model: []const u8 = "",
};

pub const Db = struct {
    sess: fr.Session,
    io: Io,
    allocator: Allocator,
    /// 打开时的库路径（worker 需要自建连接时用）
    path: [:0]const u8 = "",

    const schema =
        \\CREATE TABLE IF NOT EXISTS "session" (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL DEFAULT '',
        \\  created_at INTEGER NOT NULL,
        \\  last_active_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS "message" (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  session_id INTEGER NOT NULL REFERENCES "session"(id) ON DELETE CASCADE,
        \\  role TEXT NOT NULL,
        \\  content TEXT NOT NULL,
        \\  model TEXT NOT NULL DEFAULT '',
        \\  provider TEXT NOT NULL DEFAULT '',
        \\  created_at INTEGER NOT NULL,
        \\  reasoning TEXT NOT NULL DEFAULT '',
        \\  reasoning_ms INTEGER NOT NULL DEFAULT 0,
        \\  tool_calls TEXT NOT NULL DEFAULT '',
        \\  tool_call_id TEXT NOT NULL DEFAULT '',
        \\  tool_name TEXT NOT NULL DEFAULT '',
        \\  tool_display TEXT NOT NULL DEFAULT '',
        \\  tool_full TEXT NOT NULL DEFAULT '',
        \\  is_error INTEGER NOT NULL DEFAULT 0,
        \\  input_tokens INTEGER NOT NULL DEFAULT 0,
        \\  cached_tokens INTEGER NOT NULL DEFAULT 0,
        \\  output_tokens INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE TABLE IF NOT EXISTS "compaction" (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  session_id INTEGER NOT NULL REFERENCES "session"(id) ON DELETE CASCADE,
        \\  created_at INTEGER NOT NULL,
        \\  summary TEXT NOT NULL,
        \\  summary_message_id INTEGER NOT NULL DEFAULT 0,
        \\  tail_start_id INTEGER NOT NULL,
        \\  tokens_before INTEGER NOT NULL DEFAULT 0,
        \\  model TEXT NOT NULL DEFAULT ''
        \\);
        \\CREATE INDEX IF NOT EXISTS "idx_compaction_session" ON "compaction"(session_id, id);
        \\CREATE INDEX IF NOT EXISTS "idx_message_session" ON "message"(session_id, id);
        \\CREATE VIRTUAL TABLE IF NOT EXISTS "message_fts" USING fts5(content, content='message', content_rowid='id', tokenize='trigram');
        \\CREATE TRIGGER IF NOT EXISTS "message_ai" AFTER INSERT ON "message" BEGIN
        \\  INSERT INTO "message_fts"(rowid, content) VALUES (new.id, new.content);
        \\END;
        \\CREATE TRIGGER IF NOT EXISTS "message_ad" AFTER DELETE ON "message" BEGIN
        \\  INSERT INTO "message_fts"("message_fts", rowid, content) VALUES ('delete', old.id, old.content);
        \\END;
        \\CREATE TRIGGER IF NOT EXISTS "message_au" AFTER UPDATE ON "message" BEGIN
        \\  INSERT INTO "message_fts"("message_fts", rowid, content) VALUES ('delete', old.id, old.content);
        \\  INSERT INTO "message_fts"(rowid, content) VALUES (new.id, new.content);
        \\END;
    ;

    /// 库结构版本：不一致时删表重建（破坏性升级；相邻版本可无损迁移）
    const schema_version: i64 = 7;

    pub fn open(allocator: Allocator, io: Io) !Db {
        return openFile(allocator, io, "skynet.db");
    }

    pub fn openFile(allocator: Allocator, io: Io, filename: [:0]const u8) !Db {
        var sess = try fr.Session.open(fr.SQLite3, allocator, io, .{
            .filename = filename,
            .busy_timeout = 5000,
            .foreign_keys = .on,
        });
        errdefer sess.deinit();
        const path_copy = try allocator.dupeZ(u8, filename);
        errdefer allocator.free(path_copy);

        try sess.conn.execAll("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");

        // 版本不符：丢弃旧表（含 FTS 索引与触发器）后重建
        const Version = struct { user_version: i64 = 0 };
        var current: i64 = 0;
        if (sess.raw("SELECT user_version FROM pragma_user_version", .{}).fetchAll(Version)) |rows| {
            if (rows.len > 0) current = rows[0].user_version;
        } else |_| {}
        if (current != schema_version) {
            // current == 0 = 全新库（无 schema），无需迁移、也谈不上"数据丢失"
            if (current != 0) {
                Log.warn(.db, "schema 版本不符（{d} → {d}）: {s}", .{ current, schema_version, filename });
            }
            // v5 → v6：新增 usage 列 + compaction 表；v6 → v7：compaction 增加摘要消息引用
            var migrated = false;
            if (current == 5 or current == 6) {
                if (current == 5) {
                    if (!tableHasColumn(allocator, &sess, "message", "input_tokens")) {
                        sess.conn.execAll("ALTER TABLE \"message\" ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0;") catch {};
                    }
                    if (!tableHasColumn(allocator, &sess, "message", "cached_tokens")) {
                        sess.conn.execAll("ALTER TABLE \"message\" ADD COLUMN cached_tokens INTEGER NOT NULL DEFAULT 0;") catch {};
                    }
                    if (!tableHasColumn(allocator, &sess, "message", "output_tokens")) {
                        sess.conn.execAll("ALTER TABLE \"message\" ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0;") catch {};
                    }
                }
                // v5 还没有 compaction 表（由 schema 直接建新表，天然带列）；v6 需要 ALTER
                var compaction_ok = true;
                if (current == 6) {
                    if (!tableHasColumn(allocator, &sess, "compaction", "summary_message_id")) {
                        sess.conn.execAll("ALTER TABLE \"compaction\" ADD COLUMN summary_message_id INTEGER NOT NULL DEFAULT 0;") catch {};
                    }
                    compaction_ok = tableHasColumn(allocator, &sess, "compaction", "summary_message_id");
                }
                migrated = tableHasColumn(allocator, &sess, "message", "input_tokens") and
                    tableHasColumn(allocator, &sess, "message", "cached_tokens") and
                    tableHasColumn(allocator, &sess, "message", "output_tokens") and
                    compaction_ok;
            }
            if (!migrated) {
                if (current != 0) Log.warn(.db, "无法无损迁移：删表重建（旧会话数据将丢失）", .{});
                try sess.conn.execAll(
                    \\DROP TRIGGER IF EXISTS "message_ai";
                    \\DROP TRIGGER IF EXISTS "message_ad";
                    \\DROP TRIGGER IF EXISTS "message_au";
                    \\DROP TABLE IF EXISTS "message_fts";
                    \\DROP TABLE IF EXISTS "compaction";
                    \\DROP TABLE IF EXISTS "message";
                    \\DROP TABLE IF EXISTS "session";
                );
            }
        }

        try sess.conn.execAll(schema);
        try sess.conn.execAll(std.fmt.comptimePrint("PRAGMA user_version = {d};", .{schema_version}));

        Log.info(.db, "数据库就绪 {s} schema={d}（原 {d}）", .{ filename, schema_version, current });

        return .{ .sess = sess, .io = io, .allocator = allocator, .path = path_copy };
    }

    pub fn deinit(self: *Db) void {
        if (self.path.len > 0) self.allocator.free(self.path);
        self.sess.deinit();
    }

    fn now(self: *Db) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    /// 创建新会话，返回自增 id
    pub fn createSession(self: *Db, title: []const u8) !i64 {
        const ts = self.now();
        try self.sess.exec(
            "INSERT INTO \"session\" (title, created_at, last_active_at) VALUES (?, ?, ?)",
            .{ title, ts, ts },
        );
        return try self.sess.conn.lastInsertRowId();
    }

    /// 最近一次活跃的会话（按 last_active_at；不能按 id 最大——CLI/测试新建的
    /// 会话 id 更大但可能很久未用，会导致启动时恢复错会话）
    pub fn latestSession(self: *Db) !?SessionInfo {
        const rows = try self.sess.raw(
            "SELECT id, title, created_at, last_active_at FROM \"session\"",
            .{},
        ).orderBy("last_active_at DESC, id DESC").limit(1).fetchAll(SessionInfo);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// 标记会话为"最近访问"（打开/切换会话时调用；错开同秒创建时的排序）
    pub fn touchSession(self: *Db, session_id: i64) !void {
        try self.sess.exec("UPDATE \"session\" SET last_active_at = ? WHERE id = ?", .{ self.now(), session_id });
    }

    /// 会话是否存在
    pub fn sessionExists(self: *Db, session_id: i64) !bool {
        const Count = struct { n: i64 = 0 };
        const rows = try self.sess.raw(
            "SELECT COUNT(*) AS n FROM \"session\" WHERE id = ?",
            .{session_id},
        ).fetchAll(Count);
        return rows.len > 0 and rows[0].n > 0;
    }

    /// 单个会话信息（不存在返回 null）
    pub fn sessionInfo(self: *Db, session_id: i64) !?SessionInfo {
        const rows = try self.sess.raw(
            "SELECT id, title, created_at, last_active_at FROM \"session\" WHERE id = ?",
            .{session_id},
        ).fetchAll(SessionInfo);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// SQLite data_version：其他连接提交后会变化（用于发现外部写入）
    pub fn dataVersion(self: *Db) !i64 {
        const Row = struct { data_version: i64 = 0 };
        const rows = try self.sess.raw("SELECT data_version FROM pragma_data_version", .{}).fetchAll(Row);
        return if (rows.len > 0) rows[0].data_version else 0;
    }

    /// 加载某会话中 id 大于 after_id 的消息（按 id 升序，用于增量刷新）
    pub fn loadMessagesAfter(self: *Db, session_id: i64, after_id: i64) ![]const MessageRow {
        return try self.sess.raw(
            "SELECT id, session_id, role, content, model, provider, created_at, reasoning, reasoning_ms, tool_calls, tool_call_id, tool_name, tool_display, tool_full, is_error, input_tokens, cached_tokens, output_tokens FROM \"message\"",
            .{},
        ).where("session_id = ? AND id > ?", .{ session_id, after_id }).orderBy("id").fetchAll(MessageRow);
    }

    /// 加载某会话中 id >= min_id 的消息（压缩后加载保留区）
    pub fn loadMessagesFrom(self: *Db, session_id: i64, min_id: i64) ![]const MessageRow {
        return try self.sess.raw(
            "SELECT id, session_id, role, content, model, provider, created_at, reasoning, reasoning_ms, tool_calls, tool_call_id, tool_name, tool_display, tool_full, is_error, input_tokens, cached_tokens, output_tokens FROM \"message\"",
            .{},
        ).where("session_id = ? AND id >= ?", .{ session_id, min_id }).orderBy("id").fetchAll(MessageRow);
    }

    /// 写入一条压缩 checkpoint（summary_message_id 指向 role='summary' 的消息行）
    pub fn insertCompaction(
        self: *Db,
        session_id: i64,
        summary: []const u8,
        summary_message_id: i64,
        tail_start_id: i64,
        tokens_before: i64,
        model: []const u8,
    ) !i64 {
        try self.sess.exec(
            "INSERT INTO \"compaction\" (session_id, created_at, summary, summary_message_id, tail_start_id, tokens_before, model) VALUES (?, ?, ?, ?, ?, ?, ?)",
            .{ session_id, self.now(), summary, summary_message_id, tail_start_id, tokens_before, model },
        );
        return try self.sess.conn.lastInsertRowId();
    }

    /// 最近一次压缩 checkpoint（无则 null）
    pub fn latestCompaction(self: *Db, session_id: i64) !?CompactionRow {
        const rows = try self.sess.raw(
            "SELECT id, session_id, created_at, summary, summary_message_id, tail_start_id, tokens_before, model FROM \"compaction\"",
            .{},
        ).where("session_id = ?", .{session_id}).orderBy("id DESC").limit(1).fetchAll(CompactionRow);
        if (rows.len == 0) return null;
        return rows[0];
    }

    /// 会话列表（按最近活跃排序，含消息数）
    pub fn listSessions(self: *Db) ![]const SessionListRow {
        return try self.sess.raw(
            "SELECT s.id, s.title, s.created_at, s.last_active_at, COUNT(m.id) AS msg_count " ++
                "FROM \"session\" s LEFT JOIN \"message\" m ON m.session_id = s.id " ++
                "GROUP BY s.id",
            .{},
        ).orderBy("s.last_active_at DESC, s.id DESC").fetchAll(SessionListRow);
    }

    /// 删除会话及其全部消息（显式先删消息，保证 FTS 索引由触发器正确清理）
    pub fn deleteSession(self: *Db, session_id: i64) !void {
        try self.sess.exec("DELETE FROM \"message\" WHERE session_id = ?", .{session_id});
        try self.sess.exec("DELETE FROM \"session\" WHERE id = ?", .{session_id});
    }

    /// 插入一条消息，返回消息 id
    pub fn insertMessage(self: *Db, msg: NewMessage) !i64 {
        const ts = self.now();
        try self.sess.exec(
            "INSERT INTO \"message\" (session_id, role, content, model, provider, created_at, reasoning, reasoning_ms, tool_calls, tool_call_id, tool_name, tool_display, tool_full, is_error, input_tokens, cached_tokens, output_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            .{
                msg.session_id,
                msg.role,
                msg.content,
                msg.model,
                msg.provider,
                ts,
                msg.reasoning,
                msg.reasoning_ms,
                msg.tool_calls,
                msg.tool_call_id,
                msg.tool_name,
                msg.tool_display,
                msg.tool_full,
                msg.is_error,
                msg.input_tokens,
                msg.cached_tokens,
                msg.output_tokens,
            },
        );
        const id = try self.sess.conn.lastInsertRowId();
        try self.sess.exec("UPDATE \"session\" SET last_active_at = ? WHERE id = ?", .{ ts, msg.session_id });
        return id;
    }

    /// 更新消息内容（用于旧会话 system prompt 升级）
    pub fn updateMessageContent(self: *Db, id: i64, content: []const u8) !void {
        try self.sess.exec("UPDATE \"message\" SET content = ? WHERE id = ?", .{ content, id });
    }

    /// 折叠一条工具结果：content 替换为 stub，全文存入 tool_full。
    /// 已折叠过（tool_full 非空）时不覆盖。
    pub fn foldToolMessage(self: *Db, id: i64, folded_content: []const u8, full_content: []const u8) !void {
        try self.sess.exec(
            "UPDATE \"message\" SET content = ?, tool_full = ? WHERE id = ? AND tool_full = ''",
            .{ folded_content, full_content, id },
        );
    }

    /// 加载指定会话的全部消息（按时间顺序）
    pub fn loadMessages(self: *Db, session_id: i64) ![]const MessageRow {
        return try self.sess.raw(
            "SELECT id, session_id, role, content, model, provider, created_at, reasoning, reasoning_ms, tool_calls, tool_call_id, tool_name, tool_display, tool_full, is_error, input_tokens, cached_tokens, output_tokens FROM \"message\"",
            .{},
        ).where("session_id = ?", .{session_id}).orderBy("id").fetchAll(MessageRow);
    }

    /// 会话标题为空时，用首条用户消息设置标题
    pub fn maybeSetSessionTitle(self: *Db, session_id: i64, content: []const u8) !void {
        const title = titleFromContent(content);
        if (title.len == 0) return;
        try self.sess.exec(
            "UPDATE \"session\" SET title = ? WHERE id = ? AND title = ''",
            .{ title, session_id },
        );
    }
};

/// 表是否存在指定列（用于判断能否无损迁移）
fn tableHasColumn(allocator: Allocator, sess: *fr.Session, table: []const u8, column: []const u8) bool {
    const sql = std.fmt.allocPrint(allocator, "SELECT name FROM pragma_table_info('{s}')", .{table}) catch return false;
    defer allocator.free(sql);
    const rows = sess.raw(sql, .{}).fetchAll(struct { name: []const u8 = "" }) catch return false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.name, column)) return true;
    }
    return false;
}

/// 从消息内容截取会话标题（最多 30 个字符，遇换行截止）
pub fn titleFromContent(content: []const u8) []const u8 {
    var i: usize = 0;
    var chars: usize = 0;
    while (i < content.len and chars < 30) {
        if (content[i] == '\n') break;
        const len = std.unicode.utf8ByteSequenceLength(content[i]) catch 1;
        if (i + len > content.len) break;
        i += len;
        chars += 1;
    }
    return content[0..i];
}

// ── 测试 ──

const testing = std.testing;

fn testIo(threaded: *std.Io.Threaded) Io {
    threaded.* = .init(testing.allocator, .{});
    return threaded.io();
}

test "titleFromContent: 截断、换行、中文" {
    try testing.expectEqualStrings("hello", titleFromContent("hello\nworld"));
    try testing.expectEqualStrings("", titleFromContent("\n"));
    try testing.expectEqualStrings("hello", titleFromContent("hello"));

    // 超过 30 字符截断（ASCII）
    const long = "0123456789012345678901234567890123456789";
    try testing.expectEqualStrings("012345678901234567890123456789", titleFromContent(long));

    // 中文按字符数截断（每字 3 字节）
    const cjk = "中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文中文";
    try testing.expectEqual(@as(usize, 30 * 3), titleFromContent(cjk).len);
}

test "db: 会话与消息生命周期" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    var db = try Db.openFile(testing.allocator, io, ":memory:");
    defer db.deinit();

    // 空库
    try testing.expect((try db.latestSession()) == null);

    // 建会话 + 消息
    const sid = try db.createSession("");
    _ = try db.insertMessage(.{ .session_id = sid, .role = "system", .content = "You are helpful" });
    _ = try db.insertMessage(.{ .session_id = sid, .role = "user", .content = "帮我写个 Zig 函数" });
    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "assistant",
        .content = "好的，这是示例",
        .model = "test-model",
        .provider = "test-provider",
        .reasoning = "先想一下再回答",
        .reasoning_ms = 1500,
    });
    // 工具交互：assistant 带 tool_calls + tool 结果
    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "assistant",
        .content = "",
        .tool_calls = "[{\"id\":\"call_1\",\"name\":\"ls\",\"arguments\":\"{\\\"path\\\":\\\".\\\"}\"}]",
    });
    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "tool",
        .content = "src/\n",
        .tool_call_id = "call_1",
        .tool_name = "edit",
        .tool_display = "    1 - old\n    1 + new",
        .is_error = 1,
    });
    try db.maybeSetSessionTitle(sid, "帮我写个 Zig 函数");

    // 最近会话与标题
    const s = (try db.latestSession()).?;
    try testing.expectEqual(sid, s.id);
    try testing.expectEqualStrings("帮我写个 Zig 函数", s.title);

    // 消息顺序与字段
    const msgs = try db.loadMessages(sid);
    try testing.expectEqual(@as(usize, 5), msgs.len);
    try testing.expectEqualStrings("user", msgs[1].role);
    try testing.expectEqualStrings("test-model", msgs[2].model);
    try testing.expectEqualStrings("test-provider", msgs[2].provider);
    try testing.expectEqualStrings("先想一下再回答", msgs[2].reasoning);
    try testing.expectEqual(@as(i64, 1500), msgs[2].reasoning_ms);
    try testing.expectEqualStrings("", msgs[1].reasoning);
    try testing.expectEqual(@as(i64, 0), msgs[1].reasoning_ms);

    // 工具交互字段
    try testing.expectEqualStrings("assistant", msgs[3].role);
    try testing.expect(std.mem.indexOf(u8, msgs[3].tool_calls, "\"name\":\"ls\"") != null);
    try testing.expectEqualStrings("tool", msgs[4].role);
    try testing.expectEqualStrings("call_1", msgs[4].tool_call_id);
    try testing.expectEqualStrings("", msgs[3].tool_call_id);
    // 工具渲染字段往返
    try testing.expectEqualStrings("edit", msgs[4].tool_name);
    try testing.expectEqualStrings("    1 - old\n    1 + new", msgs[4].tool_display);
    try testing.expectEqual(@as(i64, 1), msgs[4].is_error);
    try testing.expectEqualStrings("", msgs[3].tool_name);

    // 标题只在为空时设置
    try db.maybeSetSessionTitle(sid, "不应覆盖");
    const s2 = (try db.latestSession()).?;
    try testing.expectEqualStrings("帮我写个 Zig 函数", s2.title);

    // 列表与消息计数
    const rows = try db.listSessions();
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(i64, 5), rows[0].msg_count);
}

test "db: 删除会话清理消息与 FTS 索引" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    var db = try Db.openFile(testing.allocator, io, ":memory:");
    defer db.deinit();

    const s1 = try db.createSession("");
    _ = try db.insertMessage(.{ .session_id = s1, .role = "user", .content = "被删除会话关键词：苹果香蕉" });
    const s2 = try db.createSession("");
    _ = try db.insertMessage(.{ .session_id = s2, .role = "user", .content = "保留会话关键词：橘子西瓜" });

    try db.deleteSession(s1);

    // 会话与消息移除
    try testing.expectEqual(@as(usize, 0), (try db.loadMessages(s1)).len);
    const rows = try db.listSessions();
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(s2, rows[0].id);

    // FTS 外部内容索引完整性
    try db.sess.exec("INSERT INTO \"message_fts\"(\"message_fts\") VALUES('integrity-check')", .{});

    const Hit = struct { id: i64 };
    const old_hits = try db.sess.raw(
        "SELECT m.id FROM \"message_fts\" f JOIN \"message\" m ON m.id = f.rowid",
        .{},
    ).where("f.content LIKE ?", .{"%苹果香蕉%"}).fetchAll(Hit);
    try testing.expectEqual(@as(usize, 0), old_hits.len);

    const new_hits = try db.sess.raw(
        "SELECT m.id FROM \"message_fts\" f JOIN \"message\" m ON m.id = f.rowid",
        .{},
    ).where("f.content LIKE ?", .{"%橘子西瓜%"}).fetchAll(Hit);
    try testing.expectEqual(@as(usize, 1), new_hits.len);
}

test "db: 文件持久化（重开恢复）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const dir = Io.Dir.cwd();
    const path = "skynet_test.db";
    dir.deleteFile(io, path) catch {};
    dir.deleteFile(io, "skynet_test.db-wal") catch {};
    dir.deleteFile(io, "skynet_test.db-shm") catch {};
    defer {
        dir.deleteFile(io, path) catch {};
        dir.deleteFile(io, "skynet_test.db-wal") catch {};
        dir.deleteFile(io, "skynet_test.db-shm") catch {};
    }

    var sid: i64 = 0;
    {
        var db = try Db.openFile(testing.allocator, io, path);
        defer db.deinit();
        sid = try db.createSession("");
        _ = try db.insertMessage(.{ .session_id = sid, .role = "user", .content = "持久化测试" });
    }
    {
        var db = try Db.openFile(testing.allocator, io, path);
        defer db.deinit();
        const s = (try db.latestSession()).?;
        try testing.expectEqual(sid, s.id);
        try testing.expectEqual(@as(usize, 1), (try db.loadMessages(sid)).len);
    }
}

test "db: latestSession 按最近活跃（而非最大 id），touchSession 可改写排序" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const dir = Io.Dir.cwd();
    const path = "skynet_test_latest_session.db";
    dir.deleteFile(io, path) catch {};
    dir.deleteFile(io, "skynet_test_latest_session.db-wal") catch {};
    dir.deleteFile(io, "skynet_test_latest_session.db-shm") catch {};
    defer {
        dir.deleteFile(io, path) catch {};
        dir.deleteFile(io, "skynet_test_latest_session.db-wal") catch {};
        dir.deleteFile(io, "skynet_test_latest_session.db-shm") catch {};
    }

    var db = try Db.openFile(testing.allocator, io, path);
    defer db.deinit();

    // B 的 id 更大，但 A 更近活跃 → 应选中 A（旧实现按 id 最大会错误选中 B）
    const sid_a = try db.createSession("旧会话");
    const sid_b = try db.createSession("新但久未用");
    try db.sess.exec("UPDATE \"session\" SET last_active_at = ? WHERE id = ?", .{ 2000, sid_a });
    try db.sess.exec("UPDATE \"session\" SET last_active_at = ? WHERE id = ?", .{ 1000, sid_b });
    try testing.expectEqual(sid_a, (try db.latestSession()).?.id);

    // touch 后 B 变为最近访问（真实时间戳远大于测试值）
    try db.touchSession(sid_b);
    try testing.expectEqual(sid_b, (try db.latestSession()).?.id);

    // 访问会话列表的首位与 latestSession 一致
    try testing.expectEqual(sid_b, (try db.listSessions())[0].id);
}

test "db: v5 → v7 无损迁移（保留历史，补 usage 列与 compaction 表）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const dir = Io.Dir.cwd();
    const path = "skynet_test_migrate6.db";
    dir.deleteFile(io, path) catch {};
    dir.deleteFile(io, "skynet_test_migrate6.db-wal") catch {};
    dir.deleteFile(io, "skynet_test_migrate6.db-shm") catch {};
    defer {
        dir.deleteFile(io, path) catch {};
        dir.deleteFile(io, "skynet_test_migrate6.db-wal") catch {};
        dir.deleteFile(io, "skynet_test_migrate6.db-shm") catch {};
    }

    var sid: i64 = 0;
    {
        // 先造 v6 库写入数据，再降级为 v5 形态（去掉 usage 列与 compaction 表）
        var db = try Db.openFile(testing.allocator, io, path);
        defer db.deinit();
        sid = try db.createSession("");
        _ = try db.insertMessage(.{ .session_id = sid, .role = "user", .content = "迁移前的消息" });
        try db.sess.conn.execAll(
            \\DROP TABLE IF EXISTS "compaction";
            \\ALTER TABLE "message" DROP COLUMN input_tokens;
            \\ALTER TABLE "message" DROP COLUMN cached_tokens;
            \\ALTER TABLE "message" DROP COLUMN output_tokens;
            \\PRAGMA user_version = 5;
        );
    }
    {
        var db = try Db.openFile(testing.allocator, io, path);
        defer db.deinit();
        const rows = try db.loadMessages(sid);
        try testing.expectEqual(@as(usize, 1), rows.len);
        try testing.expectEqualStrings("迁移前的消息", rows[0].content);
        try testing.expectEqual(@as(i64, 0), rows[0].input_tokens);

        // 新列与 compaction 表可用
        try db.foldToolMessage(rows[0].id, "stub", "全文");
        _ = try db.insertCompaction(sid, "摘要", 0, rows[0].id, 123, "m");
        const cp = (try db.latestCompaction(sid)).?;
        try testing.expectEqualStrings("摘要", cp.summary);
        try testing.expectEqual(rows[0].id, cp.tail_start_id);
    }
}

test "db: v6 → v7 无损迁移（compaction 补 summary_message_id）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const dir = Io.Dir.cwd();
    const path = "skynet_test_migrate7.db";
    dir.deleteFile(io, path) catch {};
    dir.deleteFile(io, "skynet_test_migrate7.db-wal") catch {};
    dir.deleteFile(io, "skynet_test_migrate7.db-shm") catch {};
    defer {
        dir.deleteFile(io, path) catch {};
        dir.deleteFile(io, "skynet_test_migrate7.db-wal") catch {};
        dir.deleteFile(io, "skynet_test_migrate7.db-shm") catch {};
    }

    var cp_id: i64 = 0;
    {
        // 先造 v7 库写入 checkpoint，再降级为 v6 形态（去掉 summary_message_id 列）
        var db = try Db.openFile(testing.allocator, io, path);
        defer db.deinit();
        const sid = try db.createSession("");
        const mid = try db.insertMessage(.{ .session_id = sid, .role = "user", .content = "旧消息" });
        cp_id = try db.insertCompaction(sid, "旧摘要", 0, mid, 100, "m");
        try db.sess.conn.execAll(
            \\ALTER TABLE "compaction" DROP COLUMN summary_message_id;
            \\PRAGMA user_version = 6;
        );
    }
    {
        var db = try Db.openFile(testing.allocator, io, path);
        defer db.deinit();
        const cp = (try db.latestCompaction(1)).?;
        try testing.expectEqual(cp_id, cp.id);
        try testing.expectEqualStrings("旧摘要", cp.summary);
        try testing.expectEqual(@as(i64, 0), cp.summary_message_id);
    }
}

test "db: 版本不一致时重建（破坏性升级）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const dir = Io.Dir.cwd();
    const path = "skynet_test_v2.db";
    dir.deleteFile(io, path) catch {};
    dir.deleteFile(io, "skynet_test_v2.db-wal") catch {};
    dir.deleteFile(io, "skynet_test_v2.db-shm") catch {};
    defer {
        dir.deleteFile(io, path) catch {};
        dir.deleteFile(io, "skynet_test_v2.db-wal") catch {};
        dir.deleteFile(io, "skynet_test_v2.db-shm") catch {};
    }

    // 手工构造旧版本库（带数据）
    {
        var sess = try fr.Session.open(fr.SQLite3, testing.allocator, io, .{
            .filename = path,
            .busy_timeout = 5000,
            .foreign_keys = .on,
        });
        defer sess.deinit();
        try sess.conn.execAll(
            \\CREATE TABLE "session" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  title TEXT NOT NULL DEFAULT '',
            \\  created_at INTEGER NOT NULL,
            \\  last_active_at INTEGER NOT NULL
            \\);
            \\CREATE TABLE "message" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  session_id INTEGER NOT NULL,
            \\  role TEXT NOT NULL,
            \\  content TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL
            \\);
            \\PRAGMA user_version = 1;
        );
        try sess.exec("INSERT INTO \"session\" (title, created_at, last_active_at) VALUES ('旧会话', 1, 1)", .{});
        try sess.exec("INSERT INTO \"message\" (session_id, role, content, created_at) VALUES (1, 'user', '旧消息', 1)", .{});
    }

    // 打开后：旧数据被清空、新 schema 可用
    var db = try Db.openFile(testing.allocator, io, path);
    defer db.deinit();

    try testing.expect((try db.latestSession()) == null);
    try testing.expectEqual(@as(usize, 0), (try db.loadMessages(1)).len);

    const sid = try db.createSession("新会话");
    _ = try db.insertMessage(.{
        .session_id = sid,
        .role = "tool",
        .content = "src/",
        .tool_call_id = "call_9",
    });
    const msgs = try db.loadMessages(sid);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("call_9", msgs[0].tool_call_id);
}
