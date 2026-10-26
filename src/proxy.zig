//! 代理配置解析：地址优先，空地址时回退环境变量（HTTP_PROXY/HTTPS_PROXY/ALL_PROXY）。
//!
//! 设计（2026-10-26 简化）：
//! - 只有一个来源：设置页「代理地址」。非空 → 用它；空 → 跟随环境变量
//! - 两个开关：AI 自身请求（for_ai）/ 工具按次使用（allow_tools，webfetch/bash 的 use_proxy）
//! - 无第三个状态：不使用代理 = 关掉相应开关（代理只在开关/参数开启时生效）
//! - localhost / 127.0.0.1 / ::1 永远直连（不被代理劫持，保护 LM Studio 等本地端点）
const std = @import("std");

pub const Settings = struct {
    /// 代理地址（可省略 http:// 前缀）。空 = 跟随环境变量
    url: []const u8 = "",
    /// AI 自身请求（对话/压缩/模型列表）经代理
    for_ai: bool = false,
    /// 允许 AI 在工具调用（webfetch/bash 的 use_proxy 参数）中使用代理
    allow_tools: bool = false,
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

/// 解析有效代理 URL（分配，调用方 free）。null = 直连。
/// 优先级：设置页地址 > 环境变量。
pub fn resolveAny(
    a: std.mem.Allocator,
    settings: Settings,
    env: ?*const std.process.Environ.Map,
) ?[]u8 {
    if (settings.url.len > 0) return normalizeCustom(a, settings.url);
    const env_url = envProxy(env) orelse return null;
    return a.dupe(u8, env_url) catch null;
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

/// 从 URI 取主机名裸切片（std.Uri.host 的 Component 解包）
pub fn uriHost(uri: std.Uri) []const u8 {
    const h = uri.host orelse return "";
    return switch (h) {
        .raw => |raw| raw,
        .percent_encoded => |pe| pe,
    };
}

/// 该主机是否应绕过代理直连：loopback + *.localhost + IPv4 私有/保留段（LAN/NAS/内网服务）。
/// std 客户端不支持 NO_PROXY，curl 路径靠注入的 NO_PROXY，两条路径统一用这里的判定。
pub fn shouldBypassProxy(host_raw: []const u8) bool {
    const h = std.mem.trim(u8, host_raw, " \t[]");
    if (isLocalHost(h)) return true;
    if (std.ascii.endsWithIgnoreCase(h, ".localhost")) return true;
    const ip = ipv4Octets(h) orelse return false;
    if (ip[0] == 127) return true; // 127.0.0.0/8
    if (ip[0] == 10) return true; // 10/8
    if (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) return true; // 172.16/12
    if (ip[0] == 192 and ip[1] == 168) return true; // 192.168/16
    if (ip[0] == 169 and ip[1] == 254) return true; // link-local
    return false;
}

fn ipv4Octets(h: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, h, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4 or part.len == 0 or part.len > 3) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return out;
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

test "proxy：本地直连判定" {
    try testing.expect(isLocalHost("localhost"));
    try testing.expect(isLocalHost("LOCALHOST"));
    try testing.expect(isLocalHost("127.0.0.1"));
    try testing.expect(isLocalHost("::1"));
    try testing.expect(!isLocalHost("example.com"));
    try testing.expect(!isLocalHost("local"));
}

test "proxy：resolveAny 地址优先，空地址跟随环境变量" {
    const a = testing.allocator;
    // 有地址：用它（自动补 http://）
    const with_url = Settings{ .url = "127.0.0.1:7890" };
    const p1 = resolveAny(a, with_url, null).?;
    defer a.free(p1);
    try testing.expectEqualStrings("http://127.0.0.1:7890", p1);
    // 空地址 + 环境变量：回退
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "http://10.0.0.1:8080");
    const p2 = resolveAny(a, .{}, &env).?;
    defer a.free(p2);
    try testing.expectEqualStrings("http://10.0.0.1:8080", p2);
    // 地址优先于环境变量
    const p3 = resolveAny(a, with_url, &env).?;
    defer a.free(p3);
    try testing.expectEqualStrings("http://127.0.0.1:7890", p3);
    // 都为空：直连
    try testing.expect(resolveAny(a, .{}, null) == null);
}

test "proxy：shouldBypassProxy（loopback / *.localhost / 私有段）" {
    try testing.expect(shouldBypassProxy("127.0.0.1"));
    try testing.expect(shouldBypassProxy("127.0.0.2"));
    try testing.expect(shouldBypassProxy("localhost"));
    try testing.expect(shouldBypassProxy("nas.localhost"));
    try testing.expect(shouldBypassProxy("10.0.0.5"));
    try testing.expect(shouldBypassProxy("172.16.1.1"));
    try testing.expect(shouldBypassProxy("172.31.255.255"));
    try testing.expect(shouldBypassProxy("192.168.1.10"));
    try testing.expect(shouldBypassProxy("169.254.1.1"));
    try testing.expect(!shouldBypassProxy("172.32.0.1"));
    try testing.expect(!shouldBypassProxy("8.8.8.8"));
    try testing.expect(!shouldBypassProxy("opencode.ai"));
    try testing.expect(!shouldBypassProxy("1.2.3.4.5"));
}
