//! 轻量查询辅助：绕过 fridge 的 RawQuery 构造开销。
//!
//! 背景：fridge 的 `Session.arena` 是"整个会话生命周期"的 arena，所有查询
//! （构造用的 Part 节点、SqlBuf、参数数组、以及默认的结果行）都分配在其中，
//! 只在 `Session.deinit()` 时统一释放。fridge 的设计面向"一次性会话"
//! （README："wraps the connection with an arena allocator"），而 SkyNet 是
//! 长驻 TUI 且会频繁做小查询（窗口化重载），于是每次查询约 2.9KB 的构造开销
//! 永久滞留，表现为滚动时内存只增不减。
//!
//! 本文件用 fridge **已公开的低层 API**（`Value.from` / `Connection.prepare` /
//! `Statement.next`）实现"结果与参数全走调用者 allocator"的查询路径，
//! 调用方用一个临时 arena 承接、处理完立即释放。
//!
//! 这样无需修改 vendored 的 fridge 源码（保持上游同步零冲突）。

const std = @import("std");
const fr = @import("fridge");

/// 执行参数化查询并把全部行读入 `allocator`（通常是一个临时 arena）。
/// SQL 与参数均由调用方保证；返回的切片及其中的字符串都归属 `allocator`。
pub fn queryAll(
    session: *fr.Session,
    allocator: std.mem.Allocator,
    comptime R: type,
    sql: []const u8,
    args: anytype,
) ![]const R {
    // 1) 参数数组：分配在调用者 allocator（fridge 的 Session.prepare 会分配在 session arena）
    const fields = std.meta.fields(@TypeOf(args));
    const values = try allocator.alloc(fr.Value, fields.len);
    inline for (fields, 0..) |f, i| {
        values[i] = try fr.Value.from(@field(args, f.name), allocator);
    }

    // 2) prepare + 逐行读取：Statement.next 接受 allocator，结果直接落调用者 arena
    var stmt = try session.conn.prepare(sql, values);
    defer stmt.deinit();

    var out = std.array_list.Managed(R).init(allocator);
    errdefer out.deinit();
    while (try stmt.next(R, allocator)) |row| {
        try out.append(row);
    }
    return out.toOwnedSlice();
}

/// 单参数便捷版本（`?` 数量为 1 时使用）。
pub fn queryAll1(
    session: *fr.Session,
    allocator: std.mem.Allocator,
    comptime R: type,
    sql: []const u8,
    arg: anytype,
) ![]const R {
    const values = try allocator.alloc(fr.Value, 1);
    values[0] = try fr.Value.from(arg, allocator);
    var stmt = try session.conn.prepare(sql, values);
    defer stmt.deinit();

    var out = std.array_list.Managed(R).init(allocator);
    errdefer out.deinit();
    while (try stmt.next(R, allocator)) |row| {
        try out.append(row);
    }
    return out.toOwnedSlice();
}

/// 无参数便捷版本。
pub fn queryAll0(
    session: *fr.Session,
    allocator: std.mem.Allocator,
    comptime R: type,
    sql: []const u8,
) ![]const R {
    var stmt = try session.conn.prepare(sql, &.{});
    defer stmt.deinit();

    var out = std.array_list.Managed(R).init(allocator);
    errdefer out.deinit();
    while (try stmt.next(R, allocator)) |row| {
        try out.append(row);
    }
    return out.toOwnedSlice();
}

/// 双参数便捷版本。
pub fn queryAll2(
    session: *fr.Session,
    allocator: std.mem.Allocator,
    comptime R: type,
    sql: []const u8,
    a: anytype,
    b: anytype,
) ![]const R {
    const values = try allocator.alloc(fr.Value, 2);
    values[0] = try fr.Value.from(a, allocator);
    values[1] = try fr.Value.from(b, allocator);
    var stmt = try session.conn.prepare(sql, values);
    defer stmt.deinit();

    var out = std.array_list.Managed(R).init(allocator);
    errdefer out.deinit();
    while (try stmt.next(R, allocator)) |row| {
        try out.append(row);
    }
    return out.toOwnedSlice();
}

/// 三参数便捷版本。
pub fn queryAll3(
    session: *fr.Session,
    allocator: std.mem.Allocator,
    comptime R: type,
    sql: []const u8,
    a: anytype,
    b: anytype,
    c: anytype,
) ![]const R {
    const values = try allocator.alloc(fr.Value, 3);
    values[0] = try fr.Value.from(a, allocator);
    values[1] = try fr.Value.from(b, allocator);
    values[2] = try fr.Value.from(c, allocator);
    var stmt = try session.conn.prepare(sql, values);
    defer stmt.deinit();

    var out = std.array_list.Managed(R).init(allocator);
    errdefer out.deinit();
    while (try stmt.next(R, allocator)) |row| {
        try out.append(row);
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "queryAll：参数化查询结果归属调用者 allocator" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    var sess = try fr.Session.open(fr.SQLite3, testing.allocator, io, .{
        .filename = ":memory:",
        .busy_timeout = 5000,
        .foreign_keys = .on,
    });
    defer sess.deinit();

    try sess.conn.execAll(
        \\CREATE TABLE "t" (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        \\INSERT INTO "t" (name) VALUES ('a'), ('b'), ('c');
    );

    const Row = struct { id: i64 = 0, name: []const u8 = "" };

    // 临时 arena 承接结果：离开作用域即整体释放
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const rows = try queryAll1(&sess, scratch.allocator(), Row, "SELECT id, name FROM \"t\" WHERE id > ? ORDER BY id", @as(i64, 1));
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("b", rows[0].name);
    try testing.expectEqualStrings("c", rows[1].name);

    // 无参数版本
    var scratch2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch2.deinit();
    const all = try queryAll0(&sess, scratch2.allocator(), Row, "SELECT id, name FROM \"t\" ORDER BY id");
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("a", all[0].name);

    // 双参数版本
    var scratch3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch3.deinit();
    const two = try queryAll2(&sess, scratch3.allocator(), Row, "SELECT id, name FROM \"t\" WHERE id >= ? AND id <= ? ORDER BY id", @as(i64, 2), @as(i64, 3));
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("b", two[0].name);
}
