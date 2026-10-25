//! 代理配置解析：配置优先（off/system/custom）> 环境变量回退（仅配置未设置时）。
//!
//! 设计（2026-10-24 定稿）：
//! - 默认全关：mode 默认 ""（未配置）+ 三个 for_* 默认 false；mode="" 时沿用
//!   HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 环境变量（向后兼容，显式配置后 env 失效）
//! - 三个消费方分开：AI 请求 / 网页抓取（webfetch）/ 终端命令（bash 子进程环境）
//! - localhost / 127.0.0.1 / ::1 永远直连（不被代理劫持，保护 LM Studio 等本地端点）
//! - system 模式：读 Windows 注册表 Internet Settings（ProxyEnable/ProxyServer）
const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum { off, system, custom };

pub const Which = enum { ai, web, bash };

pub fn modeFromString(s: []const u8) ?Mode {
    if (std.mem.eql(u8, s, "off")) return .off;
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "custom")) return .custom;
    return null;
}

pub fn modeString(m: Mode) []const u8 {
    return switch (m) {
        .off => "off",
        .system => "system",
        .custom => "custom",
    };
}

pub const Settings = struct {
    /// "" = 未配置（环境变量回退）；否则 off/system/custom
    mode: []const u8 = "",
    url: []const u8 = "",
    for_ai: bool = false,
    for_web: bool = false,
    for_bash: bool = false,

    pub fn enabledFor(self: Settings, which: Which) bool {
        return switch (which) {
            .ai => self.for_ai,
            .web => self.for_web,
            .bash => self.for_bash,
        };
    }
};

/// shell 环境变量里的代理（HTTP_PROXY/HTTPS_PROXY/ALL_PROXY，大小写都看）
pub fn envProxy(env: ?*const std.process.Environ.Map) ?[]const u8 {
    const e = env orelse return null;
    const names = [_][]const u8{ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy" };
    for (names) |n| {
        if (e.get(n)) |v| {
            if (v.len > 0) return v;
        }
    }
    return null;
}

/// 某个消费方的有效代理 URL（分配，调用方 free）。null = 直连。
/// 优先级：配置（mode 非空，且该消费方 enabledFor）> 环境变量（仅 mode 为空时）。
pub fn resolveFor(
    a: std.mem.Allocator,
    io: std.Io,
    settings: Settings,
    which: Which,
    env: ?*const std.process.Environ.Map,
) ?[]u8 {
    if (settings.mode.len == 0) {
        // 未配置：环境变量回退（老行为，与 for_* 开关无关）
        const env_url = envProxy(env) orelse return null;
        return a.dupe(u8, env_url) catch null;
    }
    const mode = modeFromString(settings.mode) orelse return null;
    if (mode == .off) return null;
    if (!settings.enabledFor(which)) return null;
    return switch (mode) {
        .off => null,
        .custom => normalizeCustom(a, settings.url),
        .system => resolveSystem(a, io),
    };
}

/// 规范化自定义代理地址："127.0.0.1:7890" → "http://127.0.0.1:7890"。
/// 非法（解析失败/非 http(s)/无主机）返回 null。
pub fn normalizeCustom(a: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.find(u8, trimmed, "://") == null) {
        return std.fmt.allocPrint(a, "http://{s}", .{trimmed}) catch null;
    }
    const parsed = std.Uri.parse(trimmed) catch return null;
    if (!std.mem.eql(u8, parsed.scheme, "http") and !std.mem.eql(u8, parsed.scheme, "https")) return null;
    return a.dupe(u8, trimmed) catch null;
}

/// 解析 ProxyServer 注册表值：
///   单值 "127.0.0.1:7890" 或 "http=127.0.0.1:7890;https=127.0.0.1:7890"。
/// 优先 https=，其次 http=，再其次整串（单值）。返回不带 scheme 的 host:port 切片。
pub fn parseProxyServer(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.findScalar(u8, trimmed, '=') == null) {
        return if (trimmed.len > 0) trimmed else null;
    }
    var https_val: ?[]const u8 = null;
    var http_val: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    while (it.next()) |part| {
        const eq = std.mem.findScalar(u8, part, '=') orelse continue;
        const k = std.mem.trim(u8, part[0..eq], " \t");
        const v = std.mem.trim(u8, part[eq + 1 ..], " \t");
        if (v.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(k, "https")) https_val = v else if (std.ascii.eqlIgnoreCase(k, "http")) http_val = v;
    }
    return https_val orelse http_val;
}

/// 读 Windows 系统代理（注册表 Internet Settings）。返回 "http://host:port"（分配）。
/// ProxyEnable=0 或读取失败 → null。非 Windows 平台恒 null。
pub fn resolveSystem(a: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (builtin.os.tag != .windows) return null;
    const enabled_raw = regQuery(a, io, "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "ProxyEnable") orelse return null;
    defer a.free(enabled_raw);
    const enabled = std.mem.trim(u8, enabled_raw, " \t");
    const on = std.mem.eql(u8, enabled, "0x1") or std.mem.eql(u8, enabled, "1");
    if (!on) return null;
    const server_raw = regQuery(a, io, "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "ProxyServer") orelse return null;
    defer a.free(server_raw);
    const hostport = parseProxyServer(server_raw) orelse return null;
    return std.fmt.allocPrint(a, "http://{s}", .{hostport}) catch null;
}

/// `reg query <subkey> /v <name>`：解析输出行末值（REG_SZ/REG_DWORD）。
fn regQuery(a: std.mem.Allocator, io: std.Io, subkey: []const u8, name: []const u8) ?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "reg", "query", subkey, "/v", name },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return null;
    defer child.kill(io);
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(8192, .none)) |_| {
        if (mr.reader(0).buffered().len > 64 * 1024) return null;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return null,
    }
    _ = child.wait(io) catch return null;
    const out = mr.toOwnedSlice(0) catch return null;
    defer a.free(out);
    // 找含 name 的行，取最后一个空白后的值
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.find(u8, line, name) == null) continue;
        var last: ?[]const u8 = null;
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        while (tok.next()) |t| last = t;
        if (last) |v| return a.dupe(u8, v) catch null;
    }
    return null;
}

/// 主机名是否本地直连（localhost/127.0.0.1/::1）
pub fn isLocalHost(host: []const u8) bool {
    const h = std.mem.trim(u8, host, " \t");
    if (std.ascii.eqlIgnoreCase(h, "localhost")) return true;
    if (std.mem.eql(u8, h, "127.0.0.1")) return true;
    if (std.mem.eql(u8, h, "::1")) return true;
    if (std.mem.eql(u8, h, "[::1]")) return true;
    return false;
}

// ── 测试 ──

const testing = std.testing;

test "proxy：mode 字符串往返" {
    try testing.expectEqual(Mode.off, modeFromString("off").?);
    try testing.expectEqual(Mode.system, modeFromString("system").?);
    try testing.expectEqual(Mode.custom, modeFromString("custom").?);
    try testing.expect(modeFromString("") == null);
    try testing.expect(modeFromString("bogus") == null);
    try testing.expectEqualStrings("custom", modeString(.custom));
}

test "proxy：normalizeCustom" {
    const a = testing.allocator;
    const v1 = normalizeCustom(a, "127.0.0.1:7890").?;
    defer a.free(v1);
    try testing.expectEqualStrings("http://127.0.0.1:7890", v1);
    const v2 = normalizeCustom(a, " http://10.0.0.1:8080 ").?;
    defer a.free(v2);
    try testing.expectEqualStrings("http://10.0.0.1:8080", v2);
    try testing.expect(normalizeCustom(a, "") == null);
    try testing.expect(normalizeCustom(a, "ftp://x:1") == null);
}

test "proxy：ProxyServer 解析" {
    try testing.expectEqualStrings("127.0.0.1:7890", parseProxyServer("127.0.0.1:7890").?);
    try testing.expect(parseProxyServer("") == null);
}

test "proxy：ProxyServer 分协议格式" {
    try testing.expectEqualStrings("127.0.0.1:7891", parseProxyServer("http=127.0.0.1:7890;https=127.0.0.1:7891").?);
    try testing.expectEqualStrings("127.0.0.1:7890", parseProxyServer("http=127.0.0.1:7890").?);
    try testing.expect(parseProxyServer(" ") == null);
}

test "proxy：本地直连判定" {
    try testing.expect(isLocalHost("localhost"));
    try testing.expect(isLocalHost("LOCALHOST"));
    try testing.expect(isLocalHost("127.0.0.1"));
    try testing.expect(isLocalHost("::1"));
    try testing.expect(!isLocalHost("example.com"));
    try testing.expect(!isLocalHost("local"));
}
