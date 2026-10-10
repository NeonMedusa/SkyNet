//! paths.zig — 数据目录解析（程序与数据分离）。
//!
//! 规则（对齐 Windows 便携软件惯例）：
//!   ① `<exe 所在目录>\data`：**无条件使用**——存在就复用，不存在就新建。
//!      scoop 安装时 `current\data` 是指向 `persist\skynet\data` 的 junction，
//!      因此程序升级/卸载（默认保留数据）都不会动数据。
//!   ② 兜底：拿不到 exe 路径、或 ① 创建失败（如只读目录）→ 退回 cwd（旧行为）。
//!
//! 显式参数 `-db` / `-config` 始终优先（由调用方处理，不经此处）。
//! 数据目录内布局：config.json、skynet.db、logs\

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// 解析结果（拥有的内存，由调用方决定何时 free）
pub const DataDir = struct {
    /// 数据目录绝对路径（无尾部分隔符）
    path: []u8,
    /// 是否为 exe 旁 data（false = 退回 cwd 的兜底模式）
    is_portable: bool,
};

/// 解析数据目录：exe 旁 `data`（不存在则新建）；失败时返回 null（调用方退回 cwd）。
pub fn resolveDataDir(io: Io, allocator: Allocator) ?DataDir {
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(exe_dir);
    return resolveDataDirAt(io, allocator, exe_dir);
}

/// 同 resolveDataDir，但以给定目录为"exe 目录"（便于测试注入）。
pub fn resolveDataDirAt(io: Io, allocator: Allocator, exe_dir: []const u8) ?DataDir {
    const data_dir = std.fs.path.join(allocator, &.{ exe_dir, "data" }) catch return null;

    // 探测：已存在（含 junction/symlink → 目录）→ 直接采用。
    // 必须先探测：Zig 的 createDirPath 对已存在的 junction 会误报 NotDir
    // （scoop persist 的 data 正是 junction），只看它的返回值会把可用目录误判为失败。
    if (openDirOk(io, data_dir)) return .{ .path = data_dir, .is_portable = true };

    // 不存在则创建（递归）；"已存在但非目录"类错误（NotDir/PathAlreadyExists）
    // 留给下面的最终探测裁决（是 junction → 可用；是文件 → 退回）。
    std.Io.Dir.createDirPath(.cwd(), io, data_dir) catch |e| switch (e) {
        error.NotDir, error.PathAlreadyExists => {},
        else => {
            allocator.free(data_dir);
            return null;
        },
    };

    // 最终裁决：必须能作为目录打开（跟随链接）才算成功
    if (openDirOk(io, data_dir)) return .{ .path = data_dir, .is_portable = true };
    allocator.free(data_dir);
    return null;
}

/// 路径能否作为目录打开（跟随符号链接/junction）
fn openDirOk(io: Io, path: []const u8) bool {
    var d = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// 在数据目录内拼一个子路径（如 "skynet.db"、"logs"、"config.json"）
pub fn join(allocator: Allocator, data_dir: []const u8, sub: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(allocator, &.{ data_dir, sub });
}

// ── 测试 ──

const testing = std.testing;

/// cwd 拼接为绝对路径（Dir 的 *Absolute 系列 API 要求绝对路径）
fn absTestPath(io: Io, rel: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);
    return std.fs.path.join(testing.allocator, &.{ cwd, rel });
}

test "paths：resolveDataDirAt 在给定 exe 目录下创建 data" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    const base_rel = "skynet_test_paths";
    const base_abs = try absTestPath(io, base_rel);
    defer testing.allocator.free(base_abs);
    defer std.Io.Dir.deleteDirAbsolute(io, base_abs) catch {};

    // 首次：创建 base 目录后解析 → data 被创建
    std.Io.Dir.createDirPath(.cwd(), io, base_abs) catch {};
    const dd = resolveDataDirAt(io, testing.allocator, base_abs).?;
    defer testing.allocator.free(dd.path);
    try testing.expect(dd.is_portable);
    try testing.expect(std.mem.endsWith(u8, dd.path, "data"));
    {
        var d = try std.Io.Dir.openDirAbsolute(io, dd.path, .{});
        d.close(io);
    }

    // 幂等：目录已存在时再次解析仍成功
    const dd2 = resolveDataDirAt(io, testing.allocator, base_abs).?;
    defer testing.allocator.free(dd2.path);
    try testing.expectEqualStrings(dd.path, dd2.path);

    // 清理：先删 data 再删 base（deleteDirAbsolute 只删空目录，非空会失败 → 忽略）
    std.Io.Dir.deleteDirAbsolute(io, dd.path) catch {};
}

test "paths：join 拼接（与 std.fs.path.join 一致）" {
    const p = try join(testing.allocator, "app_data", "skynet.db");
    defer testing.allocator.free(p);
    const expected = try std.fs.path.join(testing.allocator, &.{ "app_data", "skynet.db" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, p);
}

test "paths：data 为 junction（scoop persist）时仍解析成功" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    const io = threaded.io();
    defer threaded.deinit();

    // 场景：base/app 下 data 是指向 base/target 的 junction（scoop persist 形态）。
    // 回归：Zig 的 createDirPath 对已存在 junction 报 NotDir——旧实现会因此退回 cwd。
    const base_rel = "skynet_test_paths_junction";
    const base_abs = try absTestPath(io, base_rel);
    defer testing.allocator.free(base_abs);

    // 预计算路径（defer 里不能用 try）
    const app = std.fs.path.join(testing.allocator, &.{ base_abs, "app" }) catch return error.OutOfMemory;
    defer testing.allocator.free(app);
    const target = std.fs.path.join(testing.allocator, &.{ base_abs, "target" }) catch return error.OutOfMemory;
    defer testing.allocator.free(target);
    const data_link = std.fs.path.join(testing.allocator, &.{ app, "data" }) catch return error.OutOfMemory;
    defer testing.allocator.free(data_link);
    defer {
        // 清理（junction 先删链接，再删目录树）
        std.Io.Dir.deleteDirAbsolute(io, data_link) catch {};
        std.Io.Dir.deleteDirAbsolute(io, target) catch {};
        std.Io.Dir.deleteDirAbsolute(io, app) catch {};
        std.Io.Dir.deleteDirAbsolute(io, base_abs) catch {};
    }

    std.Io.Dir.createDirPath(.cwd(), io, app) catch {};
    std.Io.Dir.createDirPath(.cwd(), io, target) catch {};

    const mk = std.process.run(testing.allocator, io, .{
        .argv = &.{ "cmd.exe", "/c", "mklink", "/J", data_link, target },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(mk.stdout);
    defer testing.allocator.free(mk.stderr);
    switch (mk.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    // 解析：应成功且指向 app\data（而非退回 cwd 相对）
    const dd = resolveDataDirAt(io, testing.allocator, app) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(dd.path);
    try testing.expect(dd.is_portable);
    try testing.expectEqualStrings(data_link, dd.path);
    try testing.expect(std.fs.path.isAbsolute(dd.path));
}
