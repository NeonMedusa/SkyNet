//! log.zig — 迷你日志（线程安全，仅写文件）
//!
//! 用法：Log.info(.api, "请求 model={s}", .{model});
//! 文件：logs/<epoch秒>.<毫秒>.txt（每次启动一份，不覆盖历史；保留最近 20 份）
//! 级别：info（默认）；环境变量 SKYNET_LOG=off|error|warn|info|debug 覆盖
//!
//! 设计要点：
//! - **只写文件、不碰 stderr**——TUI 模式下 stderr 会破坏界面渲染；
//! - 未初始化时所有调用为 no-op（单测/无日志场景零开销、零副作用）；
//! - 每条一条 write，进程崩溃时已写内容不丢（便于事后排查断连/崩溃现场）；
//! - 不记录消息正文与密钥，只记录元数据（模型/用量/时长/尺寸/错误名）。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };

/// 日志模块标签：按模块可运行时开关（setModule）
pub const Module = enum {
    startup, // 启动/会话加载/配置
    api, // LLM 请求生命周期（发送/响应/失败/用量）
    stream, // 流式回合汇总（finalize）
    retry, // 断连重试
    tools, // 工具调用
    db, // 数据库打开/落库失败
    compact, // 上下文压缩
    fold, // 工具输出折叠
};

/// 保留最近 N 份日志文件
const keep_files = 20;
/// 单行最大长度（超出则丢弃该条）
const line_max = 1600;

var io_g: ?Io = null;
var file: ?std.Io.File = null;
var mutex: Io.Mutex = .init;
var min_level: Level = .info;
var mod_enabled: u64 = ~@as(u64, 0);

pub fn enabled() bool {
    return file != null;
}

pub fn setModule(mod: Module, on: bool) void {
    const bit = @as(u64, 1) << @intFromEnum(mod);
    if (on) mod_enabled |= bit else mod_enabled &= ~bit;
}

/// 解析级别字符串；无法识别返回 null（调用方按默认 info 处理）
pub fn parseLevel(s: []const u8) ?Level {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "err")) return .err;
    return null;
}

/// 默认初始化：logs/<epoch>.<ms>.txt；level_str 为 "off" 时完全不启用。
/// 任何一步失败都静默降级为"无日志"（绝不因日志问题影响主功能）。
pub fn init(io: Io, allocator: Allocator, level_str: []const u8) void {
    if (std.mem.eql(u8, level_str, "off")) return;
    if (parseLevel(level_str)) |l| min_level = l;

    const cwd = std.process.currentPathAlloc(io, allocator) catch return;
    defer allocator.free(cwd);
    const dir = std.fs.path.join(allocator, &.{ cwd, "logs" }) catch return;
    defer allocator.free(dir);
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};

    const ts = std.Io.Timestamp.now(io, .real).nanoseconds;
    // 注意：对**有符号**整数用 {d:0>3} 会带上 '+' 号（Zig 零填充的符号行为），
    // 因此先转无符号再格式化
    var name_buf: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.{d:0>3}.txt", .{
        @as(u64, @intCast(@divFloor(ts, 1_000_000_000))),
        @as(u32, @intCast(@divFloor(@mod(ts, 1_000_000_000), 1_000_000))),
    }) catch return;
    initPath(io, dir, name, level_str);
    pruneOldLogs(io, allocator, dir, keep_files);
}

/// 指定目录 + 文件名初始化（测试用；会覆盖同名文件并创建目录）
pub fn initPath(io: Io, dir: []const u8, name: []const u8, level_str: []const u8) void {
    if (std.mem.eql(u8, level_str, "off")) return;
    if (parseLevel(level_str)) |l| min_level = l;

    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};
    var d = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch return;
    defer d.close(io);
    // POSIX 下收紧权限（日志可能含路径等本地信息）；Windows 忽略
    const perms: std.Io.File.Permissions = if (std.Io.File.Permissions == void) {} else if (@import("builtin").os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
    file = d.createFile(io, name, .{ .truncate = true, .permissions = perms }) catch null;
    io_g = io;
}

pub fn deinit() void {
    if (file) |*f| f.close(if (io_g) |io| io else return);
    file = null;
    io_g = null;
}

/// 删除最旧的日志文件，仅保留最近 keep 份（文件名定宽，字典序 = 时间序）
fn pruneOldLogs(io: Io, allocator: Allocator, dir: []const u8, keep: usize) void {
    var d = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);

    var names = std.ArrayListUnmanaged([]u8){ .items = &.{}, .capacity = 0 };
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = d.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const copy = allocator.dupe(u8, entry.name) catch continue;
        names.append(allocator, copy) catch allocator.free(copy);
    }
    if (names.items.len <= keep) return;
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items[0 .. names.items.len - keep]) |old| {
        d.deleteFile(io, old) catch continue;
    }
}

pub fn logFn(comptime mod: Module, comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const io = io_g orelse return;
    if (file == null) return;
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;
    if ((mod_enabled >> @intFromEnum(mod)) & 1 == 0) return;

    const label = comptime switch (level) {
        .debug => "DEBG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERRO",
    };
    const mod_name = comptime @tagName(mod);
    const ts = std.Io.Timestamp.now(io, .real).nanoseconds;
    // 有符号 {d:0>3} 会带 '+' 号：先转无符号（同文件名规则）
    const sec: u64 = @intCast(@divFloor(ts, 1_000_000_000));
    const ms: u32 = @intCast(@divFloor(@mod(ts, 1_000_000_000), 1_000_000));
    var buf: [line_max]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}.{d:0>3}] [{s}] [{s}] " ++ fmt ++ "\n", .{ sec, ms, label, mod_name } ++ args) catch return;

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (file) |*f| f.writeStreamingAll(io, msg) catch {};
}

pub inline fn debug(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    logFn(mod, .debug, fmt, args);
}
pub inline fn info(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    logFn(mod, .info, fmt, args);
}
pub inline fn warn(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    logFn(mod, .warn, fmt, args);
}
pub inline fn err(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    logFn(mod, .err, fmt, args);
}

// ── 测试 ──

const testing = std.testing;

/// cwd 拼接为绝对路径（Dir 的 *Absolute 系列 API 要求绝对路径）
fn absTestPath(io: Io, rel: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);
    return std.fs.path.join(testing.allocator, &.{ cwd, rel });
}

/// 稳健清理测试目录：逐个删已知文件（目录可能非空）后再删目录
fn cleanTestDir(io: Io, dir_rel: []const u8, dir_abs: []const u8, names: []const []const u8) void {
    const cwd = std.Io.Dir.cwd();
    for (names) |n| {
        var buf: [256]u8 = undefined;
        const rel = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_rel, n }) catch continue;
        cwd.deleteFile(io, rel) catch {};
    }
    std.Io.Dir.deleteDirAbsolute(io, dir_abs) catch {};
}

fn readLogFile(io: Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(64 * 1024));
}

test "log: 未初始化时为 no-op" {
    deinit();
    info(.api, "should not crash {d}", .{1});
    try testing.expect(!enabled());
}

test "log: 文件写入/级别过滤/模块开关" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const dir_rel = "skynet_test_logs";
    const dir = try absTestPath(io, dir_rel);
    defer testing.allocator.free(dir);
    const name = "t1.txt";
    cleanTestDir(io, dir_rel, dir, &.{ name, "t2.txt" });
    defer cleanTestDir(io, dir_rel, dir, &.{ name, "t2.txt" });
    defer deinit();

    initPath(io, dir, name, "debug");
    try testing.expect(enabled());
    info(.api, "hello {d}", .{42});
    debug(.tools, "dbg line", .{});
    setModule(.api, false);
    info(.api, "hidden line", .{});
    setModule(.api, true);
    warn(.retry, "warn line", .{});
    err(.db, "err line", .{});
    deinit();

    const path = dir_rel ++ "/" ++ name;
    const content = try readLogFile(io, path);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "[INFO] [api] hello 42") != null);
    try testing.expect(std.mem.indexOf(u8, content, "[DEBG] [tools] dbg line") != null);
    try testing.expect(std.mem.indexOf(u8, content, "hidden line") == null);
    try testing.expect(std.mem.indexOf(u8, content, "[WARN] [retry] warn line") != null);
    try testing.expect(std.mem.indexOf(u8, content, "[ERRO] [db] err line") != null);
}

test "log: 级别过滤与 off" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const dir_rel = "skynet_test_logs";
    const dir = try absTestPath(io, dir_rel);
    defer testing.allocator.free(dir);
    cleanTestDir(io, dir_rel, dir, &.{ "t2.txt", "t3.txt" });
    defer {
        deinit();
        cleanTestDir(io, dir_rel, dir, &.{ "t2.txt", "t3.txt" });
    }

    initPath(io, dir, "t2.txt", "warn");
    info(.api, "info suppressed", .{});
    warn(.api, "warn written", .{});
    deinit();
    const content = try readLogFile(io, dir_rel ++ "/t2.txt");
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "info suppressed") == null);
    try testing.expect(std.mem.indexOf(u8, content, "warn written") != null);

    // off：不启用、不创建文件
    initPath(io, dir, "t3.txt", "off");
    try testing.expect(!enabled());
    info(.api, "nothing", .{});
    deinit();
    try testing.expectError(error.FileNotFound, readLogFile(io, dir_rel ++ "/t3.txt"));
}

test "log: prune 只保留最近 N 份（字典序=时间序）" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const dir_rel = "skynet_test_logs_prune";
    const dir = try absTestPath(io, dir_rel);
    defer testing.allocator.free(dir);
    const all_names = [_][]const u8{ "1000.000.txt", "1001.000.txt", "1002.000.txt", "1003.000.txt", "1004.000.txt" };
    cleanTestDir(io, dir_rel, dir, &all_names);
    defer {
        deinit();
        cleanTestDir(io, dir_rel, dir, &all_names);
    }

    // 容忍目录已存在（上次运行遗留）：非空时 delete 会失败
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};
    var d = try std.Io.Dir.openDirAbsolute(io, dir, .{});
    defer d.close(io);
    const names = [_][]const u8{ "1000.000.txt", "1001.000.txt", "1002.000.txt", "1003.000.txt", "1004.000.txt" };
    for (names) |n| {
        var f = try d.createFile(io, n, .{});
        f.close(io);
    }

    pruneOldLogs(io, testing.allocator, dir, 3);
    // 最旧的两份（1000/1001）被删，其余保留
    for (names) |n| {
        const exists = if (d.openFile(io, n, .{})) |f| blk: {
            f.close(io);
            break :blk true;
        } else |_| false;
        const should_exist = !std.mem.eql(u8, n, "1000.000.txt") and !std.mem.eql(u8, n, "1001.000.txt");
        try testing.expectEqual(should_exist, exists);
    }
}
