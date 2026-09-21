const std = @import("std");
const fr = @import("fridge");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Log = @import("log.zig");
const db_query = @import("db_query.zig");

test {
    _ = db_query;
}

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
    /// 摘要正文（降级副本：仅摘要消息行落库失败时写入；正常为空、以消息行为准）
    summary: []const u8 = "",
    /// 摘要消息行 id（role='summary'；0 = 消息行落库失败，回退到 summary 字段）
    summary_message_id: i64 = 0,
    /// 保留区起始消息 id（含）：id >= tail_start_id 的消息仍完整发送
    tail_start_id: i64 = 0,
    /// 压缩前的估算 token（展示用）
    tokens_before: i64 = 0,
    model: []const u8 = "",
};

/// 打开数据库时发现的版本不匹配信息（供上层决定：拒绝打开后如何处理）
pub const VersionMismatch = struct {
    /// 库文件中的 schema 用户版本号（> 0）
    db_version: i64 = 0,
    /// 本程序编译时的 schema 版本号
    program_version: i64 = 0,

    /// true = 库比程序旧（升级场景，可提供"重命名旧库并新建"选项）
    pub fn dbIsOlder(self: VersionMismatch) bool {
        return self.db_version < self.program_version;
    }
};

/// 只读探测数据库的 schema 版本（不打开 SQLite、不产生任何副作用：直接读文件头的
/// user_version 字段——SQLite 格式第 60 字节起 4 字节大端）。文件缺失/非 SQLite/版本 0 返回 null。
/// 用于在 openFile 因版本不符失败后，取出版本号供启动闸门展示。
pub fn probeVersionMismatch(allocator: Allocator, io: Io, filename: [:0]const u8) ?VersionMismatch {
    _ = allocator;
    const dir = Io.Dir.cwd();
    // 打开失败（含不存在）：非版本问题
    const file = dir.openFile(io, filename, .{}) catch return null;
    defer file.close(io);
    var header: [100]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return null;
    if (n < 64) return null;
    if (!std.mem.eql(u8, header[0..16], "SQLite format 3\x00")) return null;
    const ver = std.mem.readInt(u32, header[60..64], .big);
    if (ver == 0) return null; // 全新库：非"版本不符"
    return .{ .db_version = @intCast(ver), .program_version = Db.schema_version };
}

/// 选择旧库备份名：`<base>.old.db` → `<base>.old.2.db` → …（取第一个未被占用的名字；
/// 只做存在性检查，不创建任何文件）。用于弹窗展示"将重命名为 X"与实际重命名。
pub fn pickLegacyBackupName(allocator: Allocator, io: Io, filename: [:0]const u8) ![]u8 {
    const dir = Io.Dir.cwd();
    const base = std.fs.path.basename(filename);
    var n: usize = 0;
    while (n < 100) : (n += 1) {
        const candidate = if (n == 0)
            try std.fmt.allocPrint(allocator, "{s}.old.db", .{base})
        else
            try std.fmt.allocPrint(allocator, "{s}.old.{d}.db", .{ base, n + 1 });
        const taken = blk: {
            dir.access(io, candidate, .{}) catch break :blk false;
            break :blk true;
        };
        if (!taken) return candidate;
        allocator.free(candidate);
    }
    return error.TooManyBackups;
}

/// 把旧版本数据库（含 -wal / -shm / -journal 侧车文件）重命名为备份名，
/// 供用户确认后在"新建空库继续"前调用。成功返回实际使用的备份路径（调用者负责释放）。
///
/// 顺序与回滚：
///  1. 先重命名主文件（失败 = 什么都没动，直接报错返回）；
///  2. 侧车文件逐个重命名（存在才动）；任一失败则尽力把已搬走的改回原名后报错。
/// 全程只做"重命名"，不写入、不删除任何文件内容——失败时文件保持原位。
pub fn renameLegacyDbFiles(allocator: Allocator, io: Io, filename: [:0]const u8) ![]u8 {
    const dir = Io.Dir.cwd();
    const target = try pickLegacyBackupName(allocator, io, filename);
    errdefer allocator.free(target);

    dir.rename(filename, dir, target, io) catch return error.RenameFailed;

    // 侧车文件跟随主文件搬迁（未 checkpoint 的 WAL 数据必须一起走，迁移才完整）
    const suffixes = [_][]const u8{ "-wal", "-shm", "-journal" };
    var moved: usize = 0;
    for (suffixes) |suf| {
        var src_buf: [4096]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}{s}", .{ filename, suf }) catch continue;
        dir.access(io, src, .{}) catch continue; // 不存在：跳过
        var dst_buf: [4096]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}{s}", .{ target, suf }) catch continue;
        dir.rename(src, dir, dst, io) catch {
            // 回滚：把已搬迁的侧车与主文件改回原名（尽力而为）
            var k: usize = moved;
            while (k > 0) {
                k -= 1;
                var rb_src_buf: [4096]u8 = undefined;
                const rb_src = std.fmt.bufPrint(&rb_src_buf, "{s}{s}", .{ target, suffixes[k] }) catch break;
                var rb_dst_buf: [4096]u8 = undefined;
                const rb_dst = std.fmt.bufPrint(&rb_dst_buf, "{s}{s}", .{ filename, suffixes[k] }) catch break;
                dir.rename(rb_src, dir, rb_dst, io) catch {};
            }
            dir.rename(target, dir, filename, io) catch {};
            return error.RenameFailed;
        };
        moved += 1;
    }

    Log.info(.db, "旧库已重命名为备份：{s}（数据原样保留）", .{target});
    return target;
}

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

    /// 库结构版本：打开时校验，不一致**拒绝打开**（不迁移、不重建、不写入）。
    /// 全部历史迁移代码已于 2026-09 清空（尚无外部用户，一次性迁移无保留价值）；
    /// 数据库升级迁移模块将来专门设计，届时从 openFile 的版本校验处接入。
    /// TUI 启动闸门据此提示用户：旧库可经确认重命名为备份后新建空库（见 main.zig）。
    pub const schema_version: i64 = 7;

    pub fn open(allocator: Allocator, io: Io) !Db {
        return openFile(allocator, io, "skynet.db");
    }

    pub fn openFile(allocator: Allocator, io: Io, filename: [:0]const u8) !Db {
        // 版本校验安排在打开 SQLite 之前（纯读文件头）：被拒绝的库连 WAL 恢复都不触发，
        // 真正做到"一个字节都不被改动"。current == 0 = 全新库（无 schema）。
        // 说明：本项目暂无迁移逻辑（2026-09 清空全部历史迁移代码）；数据库升级迁移
        // 模块将来专门设计，届时从这里接入。
        var current: i64 = 0;
        if (probeVersionMismatch(allocator, io, filename)) |mm| current = mm.db_version;
        if (current != 0 and current != schema_version) {
            Log.err(.db, "schema 版本不符（库 {d} ≠ 程序 {d}）: 拒绝打开 {s}（不迁移、不删除）", .{ current, schema_version, filename });
            return error.SchemaVersionMismatch;
        }

        var sess = try fr.Session.open(fr.SQLite3, allocator, io, .{
            .filename = filename,
            .busy_timeout = 5000,
            .foreign_keys = .on,
        });
        errdefer sess.deinit();
        const path_copy = try allocator.dupeZ(u8, filename);
        errdefer allocator.free(path_copy);

        try sess.conn.execAll("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");

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
        // 走 db_query 路径（临时 arena）：本函数被主循环每 500ms 轮询一次，
        // 若走 fridge 的 session arena 会持续泄漏（实测 ~2.9KB/次）
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const Row = struct { data_version: i64 = 0 };
        const rows = try db_query.queryAll0(&self.sess, scratch.allocator(), Row, "SELECT data_version FROM pragma_data_version");
        return if (rows.len > 0) rows[0].data_version else 0;
    }

    /// 加载某会话中 id 大于 after_id 的消息（按 id 升序，用于增量刷新）
    /// 消息行的完整列清单（多处查询共用，避免改动时遗漏）
    const message_cols = "id, session_id, role, content, model, provider, created_at, reasoning, reasoning_ms, tool_calls, tool_call_id, tool_name, tool_display, tool_full, is_error, input_tokens, cached_tokens, output_tokens";

    pub fn loadMessagesAfter(self: *Db, session_id: i64, after_id: i64) ![]const MessageRow {
        return try self.sess.raw(
            "SELECT " ++ message_cols ++ " FROM \"message\"",
            .{},
        ).where("session_id = ? AND id > ?", .{ session_id, after_id }).orderBy("id").fetchAll(MessageRow);
    }

    /// 同 `loadMessagesAfter`，但结果与参数都分配在调用者的 allocator
    /// （临时 arena 用完即释放；不走 fridge 的 session arena，避免长驻进程累积）
    pub fn loadMessagesAfterWith(self: *Db, allocator: Allocator, session_id: i64, after_id: i64) ![]const MessageRow {
        return db_query.queryAll2(
            &self.sess,
            allocator,
            MessageRow,
            "SELECT " ++ message_cols ++ " FROM \"message\" WHERE session_id = ? AND id > ? ORDER BY id",
            session_id,
            after_id,
        );
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
            "SELECT " ++ message_cols ++ " FROM \"message\"",
            .{},
        ).where("session_id = ?", .{session_id}).orderBy("id").fetchAll(MessageRow);
    }

    /// 同上，但结果与参数都分配在调用者提供的 allocator（而非 session arena）。
    /// 调用方可用临时 arena 承接大结果集并在处理完后整体释放，
    /// 避免大批消息永久滞留在 session arena（长会话内存治理）。
    pub fn loadMessagesWith(self: *Db, allocator: Allocator, session_id: i64) ![]const MessageRow {
        return db_query.queryAll1(
            &self.sess,
            allocator,
            MessageRow,
            "SELECT " ++ message_cols ++ " FROM \"message\" WHERE session_id = ? ORDER BY id",
            session_id,
        );
    }

    /// 加载 id 落在 [lo, hi] 区间（含端点）的消息，按 id 升序。
    /// 窗口化加载用：按滚动位置加载一段，而不是整个会话。
    pub fn loadMessagesRange(self: *Db, allocator: Allocator, session_id: i64, lo_id: i64, hi_id: i64) ![]const MessageRow {
        return db_query.queryAll3(
            &self.sess,
            allocator,
            MessageRow,
            "SELECT " ++ message_cols ++ " FROM \"message\" WHERE session_id = ? AND id >= ? AND id <= ? ORDER BY id",
            session_id,
            lo_id,
            hi_id,
        );
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
    _ = try db.insertMessage(.{ .session_id = sid, .role = "user", .content = "You are helpful" });
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

test "db: 版本不一致时拒绝打开（不迁移、不重建；数据原样保留）" {
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

    // 打开被拒绝：明确报错（不是静默重建）
    try testing.expectError(error.SchemaVersionMismatch, Db.openFile(testing.allocator, io, path));

    // 文件原样保留：版本号与数据一个字节都没动
    {
        var sess = try fr.Session.open(fr.SQLite3, testing.allocator, io, .{
            .filename = path,
            .busy_timeout = 5000,
            .foreign_keys = .on,
        });
        defer sess.deinit();
        const Msg = struct { content: []const u8 = "" };
        const msgs = try sess.raw("SELECT content FROM \"message\" WHERE id = 1", .{}).fetchAll(Msg);
        try testing.expectEqual(@as(usize, 1), msgs.len);
        try testing.expectEqualStrings("旧消息", msgs[0].content);
        const Ver = struct { user_version: i64 = 0 };
        const ver = try sess.raw("SELECT user_version FROM pragma_user_version", .{}).fetchAll(Ver);
        try testing.expectEqual(@as(i64, 1), ver[0].user_version);
    }
}

test "db: 旧库重命名（侧车搬迁、冲突编号、失败不变更）与只读版本探测" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const dir = Io.Dir.cwd();
    const path: [:0]const u8 = "skynet_test_rename.db";
    const cleanup = [_][]const u8{
        "skynet_test_rename.db",
        "skynet_test_rename.db-wal",
        "skynet_test_rename.db-shm",
        "skynet_test_rename.db.old.db",
        "skynet_test_rename.db.old.db-wal",
        "skynet_test_rename.db.old.2.db",
    };
    for (cleanup) |f| dir.deleteFile(io, f) catch {};
    defer for (cleanup) |f| dir.deleteFile(io, f) catch {};

    // 构造旧库（user_version = 1）
    {
        var sess = try fr.Session.open(fr.SQLite3, testing.allocator, io, .{
            .filename = path,
            .busy_timeout = 5000,
            .foreign_keys = .on,
        });
        defer sess.deinit();
        try sess.conn.execAll("PRAGMA user_version = 1;");
    }

    // 只读探测：拿到版本号且与程序版本对比正确
    const mm = probeVersionMismatch(testing.allocator, io, path) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 1), mm.db_version);
    try testing.expectEqual(Db.schema_version, mm.program_version);
    try testing.expect(mm.dbIsOlder());
    // 探测不修改文件：仍是 v1 且数据完好
    try testing.expectEqual(@as(i64, 1), probeVersionMismatch(testing.allocator, io, path).?.db_version);

    // 手写一个假 -wal 侧车（必须在所有 SQLite 打开之后写：合法 SQLite 会清掉非法 WAL）
    {
        const f = try dir.createFile(io, "skynet_test_rename.db-wal", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "OLD-DB-WAL-DATA");
    }

    // 重命名：主文件与侧车一起搬走，原名不再存在
    const backup = try renameLegacyDbFiles(testing.allocator, io, path);
    defer testing.allocator.free(backup);
    try testing.expectEqualStrings("skynet_test_rename.db.old.db", backup);
    try testing.expectError(error.FileNotFound, dir.access(io, path, .{}));
    {
        const data = try dir.readFileAlloc(io, backup, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(data);
        try testing.expect(data.len >= 16);
        try testing.expectEqualStrings("SQLite format 3", data[0..15]);
    }
    {
        const wal = try dir.readFileAlloc(io, "skynet_test_rename.db.old.db-wal", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(wal);
        try testing.expectEqualStrings("OLD-DB-WAL-DATA", wal);
    }

    // 冲突编号：备份名已存在时改用 .old.2.db
    {
        var sess = try fr.Session.open(fr.SQLite3, testing.allocator, io, .{
            .filename = path,
            .busy_timeout = 5000,
            .foreign_keys = .on,
        });
        defer sess.deinit();
        try sess.conn.execAll("PRAGMA user_version = 1;");
    }
    const backup2 = try renameLegacyDbFiles(testing.allocator, io, path);
    defer testing.allocator.free(backup2);
    try testing.expectEqualStrings("skynet_test_rename.db.old.2.db", backup2);

    // 失败路径：源文件不存在 → RenameFailed（不产生新备份文件）
    try testing.expectError(error.RenameFailed, renameLegacyDbFiles(testing.allocator, io, path));
    try testing.expectError(error.FileNotFound, dir.access(io, "skynet_test_rename.db.old.3.db", .{}));
}
