//! webfetch 抓取层：http(s) GET + 重定向跟随 + 解压 + 大小/超时限制 + HTML→Markdown。
//!
//! 设计要点：
//! - 仅允许 http/https；重定向最多 5 跳（std.http 内置）
//! - 超时兜底：看门狗线程到点后 netShutdown(.both) 唤醒阻塞读（半开连接不会永久挂起）
//! - 响应体上限 5MB（解压后）；非文本 MIME 拒绝（图片除 SVG 外也拒绝）
//! - Cloudflare 挑战（403 + cf-mitigated: challenge）→ 换诚实 UA 重试一次（对齐 opencode）
//! - HTML 走 html.zig 转 markdown/text；其它文本类型原样返回
const std = @import("std");
const html = @import("html.zig");
const Log = @import("log.zig");
const proxy = @import("proxy.zig");

pub const Format = enum { markdown, text, html };

pub const max_body_bytes: usize = 5 * 1024 * 1024;
pub const default_timeout_ms: u32 = 30_000;
pub const max_timeout_ms: u32 = 120_000;

/// 浏览器式 UA：多数站点对非浏览器 UA 返回 403/挑战页
const browser_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36 SkyNet/0.1";
/// 挑战重试用的诚实 UA（Cloudflare 对冒充浏览器的对方更严格；opencode 同法）
const honest_ua = "Mozilla/5.0 SkyNet/0.1 (+webfetch)";

pub const Fetched = struct {
    status: u16,
    content_type: []u8,
    /// 已按 format 转换的正文（归属调用方）
    body: []u8,
};

pub const Error = error{
    InvalidUrl,
    UnsupportedScheme,
    HttpStatus,
    TooLarge,
    UnsupportedContentType,
    Timeout,
    NetworkError,
    OutOfMemory,
};

/// 抓取并转换。timeout 毫秒，钳制到 [1s, 120s]。
pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    format: Format,
    timeout_ms: u32,
    out_status: *u16,
    environ_map: ?*const std.process.Environ.Map,
) Error!Fetched {
    out_status.* = 0;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const scheme = uri.scheme;
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return error.UnsupportedScheme;

    const timeout = @max(1000, @min(timeout_ms, max_timeout_ms));

    // https + 配置了代理：std 0.17 的 CONNECT 隧道与本机 Clash 类代理不兼容
    // （同代理 curl 可用，属 std 侧问题）→ 直接走系统 curl 抓取
    if (std.mem.eql(u8, scheme, "https") and proxy.envProxy(environ_map) != null) {
        if (try curlFetch(allocator, io, environ_map.?, url, format, timeout, out_status)) |res| return res;
    }

    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const ua = if (attempt == 0) browser_ua else honest_ua;
        const res = attemptFetch(allocator, io, uri, format, timeout, ua, out_status, environ_map) catch |e| switch (e) {
            // Cloudflare 挑战：换诚实 UA 重试一次
            error.HttpStatusRetry => {
                if (attempt == 0) continue;
                return error.HttpStatus;
            },
            else => |x| return x,
        };
        return res;
    }
    return error.NetworkError;
}

const internal = error{ HttpStatusRetry };

/// 用系统 curl 抓取（正文走 stdout；状态码/内容类型用 -w 指令码拼在尾部切分）。
/// 仅用于 https+代理场景（std 0.17 的 CONNECT 隧道与 Clash 类代理不兼容，属 std 侧问题）。
/// 失败返回 null 走本地路径。
fn curlFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    url: []const u8,
    format: Format,
    timeout_ms: u32,
    out_status: *u16,
) Error!?Fetched {
    const proxy_url = proxy.envProxy(environ_map) orelse return null;

    var timeout_buf: [16]u8 = undefined;
    const timeout_s = std.fmt.bufPrint(&timeout_buf, "{d}", .{@divTrunc(timeout_ms, 1000)}) catch "30";
    const argv = [_][]const u8{
        "curl",
        "-sS",
        "-L",
        "--compressed",
        "--max-time",
        timeout_s,
        "--proxy",
        proxy_url,
        "-A",
        browser_ua,
        "-H",
        acceptHeader(format),
        "-w",
        "\n<<SKYNET-WF:%{http_code}|%{content_type}>>",
        "--url",
        url,
    };
    const run = spawnCollect(allocator, io, &argv, environ_map, max_body_bytes + 4096) orelse return null;
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);

    // 从尾部切出状态码 + content-type
    const delim = "<<SKYNET-WF:";
    const pos = std.mem.lastIndexOf(u8, run.stdout, delim) orelse {
        Log.info(.api, "webfetch curl 回退失败: {s}", .{run.stderr});
        return null;
    };
    const body_part = run.stdout[0..pos];
    const meta_end = std.mem.indexOfScalarPos(u8, run.stdout, pos, '>') orelse return null;
    const meta = run.stdout[pos + delim.len .. meta_end];
    const bar = std.mem.findScalar(u8, meta, '|') orelse return null;
    const code = std.fmt.parseInt(u16, meta[0..bar], 10) catch return null;
    out_status.* = code;
    if (code < 200 or code >= 300) return error.HttpStatus;

    const ct = try allocator.dupe(u8, std.mem.trim(u8, meta[bar + 1 ..], " \t"));
    errdefer allocator.free(ct);
    const mime = mimeOf(ct);
    if (isImage(mime) and !std.ascii.eqlIgnoreCase(mime, "image/svg+xml")) return error.UnsupportedContentType;
    if (!isTextual(mime)) return error.UnsupportedContentType;

    const raw = try allocator.dupe(u8, body_part);
    defer allocator.free(raw);
    const looks_html = std.mem.find(u8, mime, "html") != null or
        (std.mem.trim(u8, mime, " \t").len == 0 and looksLikeHtml(raw));
    const body: []u8 = if (looks_html and format != .html)
        html.convert(allocator, raw, if (format == .markdown) .markdown else .text) catch return error.OutOfMemory
    else
        try allocator.dupe(u8, raw);
    return .{ .status = code, .content_type = ct, .body = body };
}

/// 绝对路径读文件（0.17：fs.cwd 已移除，按父目录打开）
fn readFileAbs(io: std.Io, allocator: std.mem.Allocator, abs: []const u8, limit: usize) ![]u8 {
    const parent = std.fs.path.dirname(abs) orelse return error.FileNotFound;
    var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(abs), allocator, .limited(limit));
}

fn deleteFileAbs(io: std.Io, abs: []const u8) void {
    const parent = std.fs.path.dirname(abs) orelse return;
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, std.fs.path.basename(abs)) catch {};
}

const RunOutput = struct { stdout: []u8, stderr: []u8 };

/// spawn + 收集 stdout/stderr（MultiReader 模式；每路输出上限 64KB）
fn spawnCollect(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    max_out: usize,
) ?RunOutput {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = environ_map,
    }) catch return null;
    defer child.kill(io);
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(allocator, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(8192, .none)) |_| {
        if (mr.reader(0).buffered().len > max_out) return null;
        if (mr.reader(1).buffered().len > 64 * 1024) return null;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return null,
    }
    _ = child.wait(io) catch return null;
    const out = mr.toOwnedSlice(0) catch return null;
    const err = mr.toOwnedSlice(1) catch {
        allocator.free(out);
        return null;
    };
    return .{ .stdout = out, .stderr = err };
}

fn attemptFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    uri: std.Uri,
    format: Format,
    timeout_ms: u32,
    ua: []const u8,
    out_status: *u16,
    environ_map: ?*const std.process.Environ.Map,
) (Error || internal)!Fetched {
    // 注意：必须显式提供 now（TLS 证书时间校验用）。留空时首连 TLS 会 client.now.? panic——
    // 尤其 http→https 重定向路径会绕过 std 的懒初始化（2026-10 实测崩溃点）。
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
        .now = std.Io.Clock.real.now(io),  // 墙钟：TLS 证书有效期校验
    };
    defer client.deinit();
    // 代理：与 AI 客户端一致，读 HTTP_PROXY/HTTPS_PROXY/NO_PROXY（墙外站点必需；
    // 代理配置的分配域必须比客户端活得久）
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    defer proxy_arena.deinit();
    // localhost/127.0.0.1/::1 永远直连（保护本地服务，如 LM Studio）
    const target_host: []const u8 = if (uri.host) |h| switch (h) {
        .raw => |raw| raw,
        .percent_encoded => |pe| pe,
    } else "";
    if (environ_map) |env| {
        if (!proxy.isLocalHost(target_host)) {
            client.initDefaultProxies(proxy_arena.allocator(), env) catch {};
        }
    }

    var extra_headers = [_]std.http.Header{
        .{ .name = "Accept", .value = acceptHeader(format) },
        .{ .name = "Accept-Language", .value = "zh-CN,zh;q=0.9,en;q=0.8" },
    };

    var request = client.request(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = @fromBackingInt(@as(u16, 5)),
        .headers = .{
            .user_agent = .{ .override = ua },
        },
        .extra_headers = &extra_headers,
    }) catch return error.NetworkError;
    defer request.deinit();

    // 看门狗：到点 shutdown 连接，唤醒阻塞读/等头
    var wd = Watchdog{
        .io = io,
        .deadline_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() + @as(i64, @intCast(timeout_ms)),
    };
    wd.publishConnection(request.connection);
    const thread = std.Thread.spawn(.{}, watchdogMain, .{&wd}) catch return error.NetworkError;
    defer {
        wd.stop.store(true, .release);
        thread.join();
    }

    request.sendBodiless() catch {
        if (wd.timed_out.load(.acquire)) return error.Timeout;
        return error.NetworkError;
    };

    var redirect_buf: [8192]u8 = undefined;
    var response = request.receiveHead(&redirect_buf) catch {
        if (wd.timed_out.load(.acquire)) return error.Timeout;
        return error.NetworkError;
    };
    // 重定向可能换连接：刷新句柄（std.http 在 receiveHead 内部跟随）
    wd.publishConnection(request.connection);

    const status = @intFromEnum(response.head.status);
    out_status.* = @as(u16, @intCast(status));
    if (status == 403 and isCloudflareChallenge(response.head.bytes)) {
        return internal.HttpStatusRetry;
    }
    if (status < 200 or status >= 300) return error.HttpStatus;

    // 注意：response.head 的切片在 body 流初始化后失效（std.http 文档明示），
    // 必须在读 body 之前复制 content-type（2026-10 course.ziglang.cc 实测踩到：
    // 读后复制拿到垃圾字节 → MIME 判定错乱 → HTML 未转换）
    const ct = try allocator.dupe(u8, headerValue(response.head.bytes, "content-type") orelse "");
    errdefer allocator.free(ct);
    const mime = mimeOf(ct);
    if (isImage(mime) and !std.ascii.eqlIgnoreCase(mime, "image/svg+xml")) return error.UnsupportedContentType;
    if (!isTextual(mime)) return error.UnsupportedContentType;

    const raw = try readBody(allocator, &response, &wd);
    defer allocator.free(raw);

    // HTML 判定：优先 content-type；缺失/空白时按内容嗅探
    // （不少 CDN/服务端不带该头——2026-10 course.ziglang.cc 实测踩到）
    const looks_html = std.mem.find(u8, mime, "html") != null or
        (std.mem.trim(u8, mime, " \t").len == 0 and looksLikeHtml(raw));
    const body: []u8 = if (looks_html and format != .html) blk: {
        const converted = html.convert(allocator, raw, if (format == .markdown) .markdown else .text) catch return error.OutOfMemory;
        break :blk converted;
    } else try allocator.dupe(u8, raw);

    return .{
        .status = status,
        .content_type = ct,
        .body = body,
    };
}

fn readBody(allocator: std.mem.Allocator, response: *std.http.Client.Response, wd: *Watchdog) Error![]u8 {
    const head = response.head;
    const decompress_buf: []u8 = switch (head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory,
        .zstd => allocator.alloc(u8, std.compress.zstd.default_window_len) catch return error.OutOfMemory,
        .compress => return error.UnsupportedContentType,
    };
    defer if (decompress_buf.len > 0) allocator.free(decompress_buf);

    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    return reader.allocRemaining(allocator, .limited(max_body_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.TooLarge,
        else => {
            if (wd.timed_out.load(.acquire)) return error.Timeout;
            return error.NetworkError;
        },
    };
}

/// 超时看门狗：到点对当前连接 netShutdown(.both)，唤醒阻塞读。
const Watchdog = struct {
    io: std.Io,
    deadline_ms: i64,
    handle: std.atomic.Value(usize) = .init(0),
    timed_out: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),

    fn publishConnection(self: *Watchdog, conn: ?*std.http.Client.Connection) void {
        const c = conn orelse return;
        self.handle.store(handleToUsize(c.stream_reader.stream.socket.handle), .release);
    }
};

fn watchdogMain(wd: *Watchdog) void {
    while (!wd.stop.load(.acquire)) {
        const now = std.Io.Timestamp.now(wd.io, .awake).toMilliseconds();
        if (now >= wd.deadline_ms) {
            const h = wd.handle.load(.acquire);
            if (h != 0) {
                if (usizeToHandle(h)) |sock| {
                    wd.timed_out.store(true, .release);
                    wd.io.vtable.netShutdown(wd.io.userdata, sock, .both) catch {};
                }
            }
            return;
        }
        std.Io.sleep(wd.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
}

fn handleToUsize(h: std.Io.net.Socket.Handle) usize {
    return switch (@typeInfo(std.Io.net.Socket.Handle)) {
        .pointer => @intFromPtr(h),
        .int => @intCast(h),
        else => 0,
    };
}

fn usizeToHandle(u: usize) ?std.Io.net.Socket.Handle {
    return switch (@typeInfo(std.Io.net.Socket.Handle)) {
        .pointer => @ptrFromInt(u),
        .int => @intCast(u),
        else => null,
    };
}

fn acceptHeader(format: Format) []const u8 {
    return switch (format) {
        .markdown => "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1",
        .text => "text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1",
        .html => "text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, text/markdown;q=0.7, */*;q=0.1",
    };
}

fn isCloudflareChallenge(head_bytes: []const u8) bool {
    const v = headerValue(head_bytes, "cf-mitigated") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "challenge");
}

/// 从响应头原文里取某头的值（大小写不敏感；返回不含行尾空白）
pub fn headerValue(head_bytes: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = it.next(); // 状态行
    while (it.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const n = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(n, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// 内容嗅探：前 2KB 出现 HTML 特征（<!doctype html 或 <html 标签）
pub fn looksLikeHtml(raw: []const u8) bool {
    const head = raw[0..@min(raw.len, 2048)];
    if (std.ascii.findIgnoreCase(head, "<!doctype html") != null) return true;
    if (std.ascii.findIgnoreCase(head, "<html") != null) return true;
    return false;
}

fn mimeOf(ct: []const u8) []const u8 {
    const semi = std.mem.findScalar(u8, ct, ';') orelse ct.len;
    const m = std.mem.trim(u8, ct[0..semi], " \t");
    // 转小写（返回切片指向原字符串；调用方不重叠使用即可）
    return m;
}

fn isImage(mime: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(mime, "image/");
}

pub fn isTextual(mime: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(mime, "text/")) return true;
    if (std.ascii.eqlIgnoreCase(mime, "application/json")) return true;
    if (std.ascii.eqlIgnoreCase(mime, "application/xml")) return true;
    if (std.ascii.eqlIgnoreCase(mime, "application/javascript")) return true;
    if (std.ascii.eqlIgnoreCase(mime, "application/xhtml+xml")) return true;
    if (std.ascii.eqlIgnoreCase(mime, "application/x-www-form-urlencoded")) return true;
    if (std.ascii.eqlIgnoreCase(mime, "application/yaml")) return true;
    if (std.ascii.eqlIgnoreCase(mime, "application/x-yaml")) return true;
    if (std.mem.endsWith(u8, mime, "+json")) return true;
    if (std.mem.endsWith(u8, mime, "+xml")) return true;
    // 空白/缺失 content-type：当作文本尝试（很多服务端不带该头）
    if (std.mem.trim(u8, mime, " \t").len == 0) return true;
    return false;
}

// ── 测试 ──

const testing = std.testing;

test "web：响应头解析" {
    const head = "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\nCF-Mitigated: challenge\r\n\r\n";
    try testing.expectEqualStrings("text/html; charset=utf-8", headerValue(head, "content-type").?);
    try testing.expectEqualStrings("challenge", headerValue(head, "cf-mitigated").?);
    try testing.expect(isCloudflareChallenge(head));
    try testing.expect(headerValue(head, "x-none") == null);
}

test "web：MIME 文本判定" {
    try testing.expect(isTextual("text/html"));
    try testing.expect(isTextual("application/json"));
    try testing.expect(isTextual("application/ld+json"));
    try testing.expect(isTextual(""));
    try testing.expect(!isTextual("application/octet-stream"));
    try testing.expect(!isTextual("image/png"));
    try testing.expect(isImage("image/svg+xml"));
}

test "web：HTML 嗅探" {
    try testing.expect(looksLikeHtml("<!DOCTYPE html><html><body>x</body></html>"));
    try testing.expect(looksLikeHtml("<HTML lang=\"zh\">"));
    try testing.expect(!looksLikeHtml("{\"json\": true}"));
    try testing.expect(!looksLikeHtml(""));
}

test "web：URL 校验" {
    // 仅验证解析与 scheme 检查（不发起网络请求）
    const bad = std.Uri.parse("ftp://example.com/x") catch unreachable;
    try testing.expectEqualStrings("ftp", bad.scheme);
    try testing.expect(!std.mem.eql(u8, bad.scheme, "http"));
}
