//! webfetch 抓取层：http(s) GET + 重定向跟随 + 解压 + 大小/超时限制 + HTML→Markdown。
//!
//! 设计要点（2026-10-26 传输层定稿）：
//! - **优先系统 curl**（`--connect-timeout`/`--max-time` 覆盖连接阶段；std 的
//!   client.request() 内部同步 connect，看门狗只能挂建连之后——DROP 端口实测 133s）；
//!   仅在系统无 curl 时回退 std.http
//! - loopback / *.localhost / IPv4 私有段永远直连（proxy.shouldBypassProxy，std 不支持 NO_PROXY）
//! - 传输错误按 curl 退出码/ std 错误名分类（DnsFailed / ConnectionFailed / Timeout /
//!   CertificateInvalid / ProxyTunnelFailed / TlsHandshakeFailed）
//! - 响应体上限 5MB（解压后）；非文本 MIME 拒绝（图片除 SVG 外也拒绝）
//! - Cloudflare 挑战（403）→ 换诚实 UA 重试一次（对齐 opencode）
//! - HTML 走 html.zig 转 markdown/text；其它文本类型原样返回
const std = @import("std");
const assert = std.debug.assert;
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
    /// DNS 解析失败（域名不存在 / 污染 / 解析器不可用）
    DnsFailed,
    /// 连接失败（拒绝/主机不可达/网络不可达/被重置）
    ConnectionFailed,
    /// TLS 证书不受信（自签、过期、域名不匹配、可能被中间人劫持）
    CertificateInvalid,
    /// TLS 握手失败（包含证书链初始化失败等）
    TlsHandshakeFailed,
    /// 代理隧道建立失败（通常是代理侧 DNS/连接问题，并非目标站点证书问题）
    ProxyTunnelFailed,
    /// 经代理时连接失败（代理端口拒绝/不可达——通常是代理未启动，可改直连重试）
    ProxyConnectionFailed,
    NetworkError,
    OutOfMemory,
};

/// std 错误名 → 语义错误（无法归类的保留 NetworkError）
fn classifyHttpError(e: anyerror) Error {
    return switch (e) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.AddressUnavailable,
        => error.ConnectionFailed,
        error.Timeout => error.Timeout,
        error.UnknownHostName, error.NameServerFailure, error.InvalidHostName => error.DnsFailed,
        // std 的证书校验失败通常以 TlsAlert 上浮（alert 明细在 http.Client 内部不可达）；
        // webfetch 只面向正常站点，握手被拒的压倒性原因是证书校验 → 归入 CertificateInvalid。
        // TlsInitializationFailed = 本地根证书加载/初始化失败，单独归类。
        error.TlsAlert, error.TlsCertificateNotVerified => error.CertificateInvalid,
        error.TlsInitializationFailed => error.TlsHandshakeFailed,
        else => error.NetworkError,
    };
}

/// 带上下文的分类：std 把"远端证书不受信"也报成 TlsInitializationFailed（与本地
/// 根证书为空同名）。用 bundle 证书数区分：非空 → 远端证书校验失败；空 → 本地 CA 问题。
fn classifyHttpErrorCtx(e: anyerror, ca_count: usize) Error {
    if (e == error.TlsInitializationFailed) {
        return if (ca_count == 0) error.TlsHandshakeFailed else error.CertificateInvalid;
    }
    return classifyHttpError(e);
}

/// curl 退出码 → 语义错误（见 curl(1) EXIT CODES；未知码返回 null 交给调用方回退）
/// use_proxy：经代理时 exit 35 多为隧道建立失败（代理侧 DNS/连接），不是目标证书问题
fn curlExitError(code: u8, use_proxy: bool) ?Error {
    return switch (code) {
        5 => if (use_proxy) error.ProxyConnectionFailed else error.ConnectionFailed, // 代理域名解析失败
        6 => error.DnsFailed,
        7 => if (use_proxy) error.ProxyConnectionFailed else error.ConnectionFailed,
        28 => error.Timeout,
        35 => if (use_proxy) error.ProxyTunnelFailed else error.TlsHandshakeFailed,
        52, 56 => error.NetworkError, // 空回复 / 接收失败
        51, 58, 60, 77, 90, 91 => error.CertificateInvalid,
        97 => error.ProxyTunnelFailed,
        else => null,
    };
}

/// 抓取并转换。timeout 毫秒，钳制到 [1s, 120s]。
/// insecure=true 跳过 TLS 证书校验（仅用于用户的显式授权，调用方负责门控）。
pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    format: Format,
    timeout_ms: u32,
    out_status: *u16,
    environ_map: ?*const std.process.Environ.Map,
    insecure: bool,
) Error!Fetched {
    out_status.* = 0;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const scheme = uri.scheme;
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return error.UnsupportedScheme;

    const timeout = @max(1000, @min(timeout_ms, max_timeout_ms));

    // 目标主机是否应绕过代理（loopback / *.localhost / 私有网段）：
    // std 客户端不支持 NO_PROXY，必须统一在这里判定，否则 use_proxy=true 时内网服务全部被塞进代理
    const target_host = proxy.uriHost(uri);
    const via_proxy = !proxy.shouldBypassProxy(target_host) and proxy.envProxy(environ_map) != null;

    // 优先 curl：连接阶段有 --connect-timeout（std 的 client.request() 内部同步 connect，
    // 看门狗只能挂在建连之后——DROP 端口会把 timeout 参数变成摆设，2026-10 实测 133s）。
    // curl 不可用（未安装）时回退 std 路径。
    if (environ_map != null) {
        if (try curlFetch(allocator, io, environ_map.?, url, format, timeout, out_status, insecure, via_proxy, browser_ua)) |res| {
            return res;
        }
    }

    // ── std 兜底路径（curl 缺失时）────────────────────────────────
    // 注意：此路径的连接阶段不受 timeout 约束（std 限制），只有建连后的读写受看门狗保护
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

/// curl 参数表（定长，零分配）
const Argv = struct {
    buf: [24][]const u8 = undefined,
    len: usize = 0,

    fn add(self: *Argv, v: []const u8) void {
        assert(self.len < self.buf.len);
        self.buf[self.len] = v;
        self.len += 1;
    }

    fn slice(self: *const Argv) []const []const u8 {
        return self.buf[0..self.len];
    }
};

/// 用系统 curl 抓取（正文走 stdout；状态码/内容类型用 -w 指令码拼在尾部切分）。
/// 用于 https+代理（std 0.17 的 CONNECT 隧道不兼容）与 insecure（std 无跳过校验开关）。
/// 失败时按 curl 退出码返回语义化错误；无法归类/未安装 curl 返回 null 由调用方回退。
fn curlFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    url: []const u8,
    format: Format,
    timeout_ms: u32,
    out_status: *u16,
    insecure: bool,
    use_proxy: bool,
    ua: []const u8,
) Error!?Fetched {
    var timeout_buf: [16]u8 = undefined;
    const timeout_s = std.fmt.bufPrint(&timeout_buf, "{d}", .{@divTrunc(timeout_ms, 1000)}) catch "30";
    var conn_buf: [16]u8 = undefined;
    const conn_timeout_s = std.fmt.bufPrint(&conn_buf, "{d}", .{@min(@divTrunc(timeout_ms, 1000), 10)}) catch "10";
    var accept_buf: [160]u8 = undefined;
    var argv = Argv{};
    argv.add("curl");
    argv.add("-sS");
    argv.add("-L");
    argv.add("--compressed");
    argv.add("--max-time");
    argv.add(timeout_s);
    argv.add("--connect-timeout");
    argv.add(conn_timeout_s);
    if (use_proxy) {
        if (proxy.envProxy(environ_map)) |p| {
            argv.add("--proxy");
            argv.add(p);
        }
    }
    if (insecure) argv.add("-k");
    argv.add("-A");
    argv.add(ua);
    // curl 的 -H 必须带 "Name: value"——裸值会被直接丢弃（2026-10 实测服务端只收到 */*）
    argv.add("-H");
    argv.add(headerLine(&accept_buf, "Accept", acceptHeader(format)));
    argv.add("-H");
    argv.add("Accept-Language: zh-CN,zh;q=0.9,en;q=0.8");
    argv.add("-w");
    argv.add("\n<<SKYNET-WF:%{http_code}|%{content_type}>>");
    argv.add("--url");
    argv.add(url);
    const run = try spawnCollect(allocator, io, argv.slice(), environ_map, max_body_bytes + 4096) orelse return null;
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);

    // 传输层失败先看退出码（curl 失败时 -w 仍会打印 000，不能当成 HTTP 状态）
    if (run.code != 0) {
        Log.info(.api, "webfetch curl 失败(code={d}): {s}", .{ run.code, run.stderr[0..@min(run.stderr.len, 300)] });
        return curlExitError(run.code, use_proxy) orelse error.NetworkError;
    }

    // 从尾部切出状态码 + content-type
    const delim = "<<SKYNET-WF:";
    const pos = std.mem.lastIndexOf(u8, run.stdout, delim) orelse {
        Log.info(.api, "webfetch curl 输出缺失 write-out: {s}", .{run.stderr[0..@min(run.stderr.len, 300)]});
        return error.NetworkError;
    };
    const body_part = run.stdout[0..pos];
    const meta_end = std.mem.indexOfScalarPos(u8, run.stdout, pos, '>') orelse return error.NetworkError;
    const meta = run.stdout[pos + delim.len .. meta_end];
    const bar = std.mem.findScalar(u8, meta, '|') orelse return error.NetworkError;
    const code = std.fmt.parseInt(u16, meta[0..bar], 10) catch 0;
    out_status.* = code;
    if (code == 0) return error.NetworkError; // 000 不是 HTTP 状态
    if (code < 200 or code >= 300) return error.HttpStatus;

    const ct = try allocator.dupe(u8, std.mem.trim(u8, meta[bar + 1 ..], " \t"));
    errdefer allocator.free(ct);
    var mime_buf: [128]u8 = undefined;
    const mime = mimeLower(&mime_buf, ct);
    if (isImage(mime) and !std.ascii.eqlIgnoreCase(mime, "image/svg+xml")) return error.UnsupportedContentType;
    if (!isTextual(mime)) return error.UnsupportedContentType;

    const raw = try allocator.dupe(u8, body_part);
    defer allocator.free(raw);
    const looks_html = std.mem.find(u8, mime, "html") != null or
        (mime.len == 0 and looksLikeHtml(raw));
    const body: []u8 = if (looks_html and format != .html)
        html.convert(allocator, raw, if (format == .markdown) .markdown else .text) catch return error.OutOfMemory
    else
        try allocator.dupe(u8, raw);
    return .{ .status = code, .content_type = ct, .body = body };
}

/// 绝对路径读文件（0.17：fs.cwd 已移除，按父目录打开）
const RunOutput = struct { code: u8, stdout: []u8, stderr: []u8 };

/// spawn + 收集 stdout/stderr（MultiReader 模式；每路输出上限 64KB）
fn spawnCollect(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    max_out: usize,
) error{TooLarge}!?RunOutput {
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
        if (mr.reader(0).buffered().len > max_out) return error.TooLarge;
        if (mr.reader(1).buffered().len > 64 * 1024) return error.TooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return null,
    }
    const term = child.wait(io) catch return null;
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    const out = mr.toOwnedSlice(0) catch return null;
    const err = mr.toOwnedSlice(1) catch {
        allocator.free(out);
        return null;
    };
    return .{ .code = code, .stdout = out, .stderr = err };
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
        .now = std.Io.Clock.real.now(io), // 墙钟：TLS 证书有效期校验
    };
    defer client.deinit();
    // 显式赋 now 会跳过 std 的懒加载 rescan（bundle 为空 → Linux 下 HTTPS 一律
    // TlsInitializationFailed，2026-10 WSL 实测）：显式重扫系统根证书。
    // 失败保留空包（后续错误由连接阶段上交），仅记日志。
    client.ca_bundle.rescan(allocator, io, client.now.?) catch |e| {
        Log.warn(.api, "webfetch 根证书加载失败: {t}", .{e});
    };
    // 代理：与 AI 客户端一致，读 HTTP_PROXY/HTTPS_PROXY/NO_PROXY（墙外站点必需；
    // 代理配置的分配域必须比客户端活得久）
    var proxy_arena = std.heap.ArenaAllocator.init(allocator);
    defer proxy_arena.deinit();
    // loopback / *.localhost / 私有网段永远直连（保护本地服务与内网访问）
    const attempt_host = proxy.uriHost(uri);
    if (environ_map) |env| {
        if (!proxy.shouldBypassProxy(attempt_host)) {
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
    }) catch |e| return classifyHttpErrorCtx(e, client.ca_bundle.map.count());
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

    request.sendBodiless() catch |e| {
        if (wd.timed_out.load(.acquire)) return error.Timeout;
        return classifyHttpErrorCtx(e, client.ca_bundle.map.count());
    };

    var redirect_buf: [8192]u8 = undefined;
    var response = request.receiveHead(&redirect_buf) catch |e| {
        if (wd.timed_out.load(.acquire)) return error.Timeout;
        return classifyHttpErrorCtx(e, client.ca_bundle.map.count());
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
    var mime_buf: [128]u8 = undefined;
    const mime = mimeLower(&mime_buf, ct);
    if (isImage(mime) and !std.ascii.eqlIgnoreCase(mime, "image/svg+xml")) return error.UnsupportedContentType;
    if (!isTextual(mime)) return error.UnsupportedContentType;

    const raw = try readBody(allocator, &response, &wd);
    defer allocator.free(raw);

    // HTML 判定：优先 content-type；缺失/空白时按内容嗅探
    // （不少 CDN/服务端不带该头——2026-10 course.ziglang.cc 实测踩到）
    const looks_html = std.mem.find(u8, mime, "html") != null or
        (mime.len == 0 and looksLikeHtml(raw));
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

/// `-H` 参数拼装：curl 要求 "Header: value" 形式（裸值会被 curl 丢弃）
fn headerLine(buf: []u8, name: []const u8, value: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ name, value }) catch value;
}

/// Content-Type 规范化：去参数 + 转小写（写入调用方缓冲；超长时截断）。
/// 下游全部按小写比较（"TEXT/HTML" 也要能命中 html 判定）。
fn mimeLower(buf: []u8, ct: []const u8) []const u8 {
    const semi = std.mem.findScalar(u8, ct, ';') orelse ct.len;
    const m = std.mem.trim(u8, ct[0..semi], " \t");
    const n = @min(m.len, buf.len);
    for (m[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
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

test "web：错误分类（std 错误名 + curl 退出码）" {
    try testing.expectEqual(Error.ConnectionFailed, classifyHttpError(error.ConnectionRefused));
    try testing.expectEqual(Error.ConnectionFailed, classifyHttpError(error.HostUnreachable));
    try testing.expectEqual(Error.Timeout, classifyHttpError(error.Timeout));
    try testing.expectEqual(Error.DnsFailed, classifyHttpError(error.UnknownHostName));
    try testing.expectEqual(Error.DnsFailed, classifyHttpError(error.NameServerFailure));
    try testing.expectEqual(Error.CertificateInvalid, classifyHttpError(error.TlsCertificateNotVerified));
    try testing.expectEqual(Error.CertificateInvalid, classifyHttpError(error.TlsAlert));
    try testing.expectEqual(Error.TlsHandshakeFailed, classifyHttpError(error.TlsInitializationFailed));
    // 上下文判别：bundle 为空 = 本地 CA 问题；非空 = 远端证书不受信
    try testing.expectEqual(Error.TlsHandshakeFailed, classifyHttpErrorCtx(error.TlsInitializationFailed, 0));
    try testing.expectEqual(Error.CertificateInvalid, classifyHttpErrorCtx(error.TlsInitializationFailed, 121));
    try testing.expectEqual(Error.NetworkError, classifyHttpError(error.BrokenPipe));

    try testing.expectEqual(Error.DnsFailed, curlExitError(6, false).?);
    try testing.expectEqual(Error.ConnectionFailed, curlExitError(7, false).?);
    try testing.expectEqual(Error.ProxyConnectionFailed, curlExitError(7, true).?);
    try testing.expectEqual(Error.ProxyConnectionFailed, curlExitError(5, true).?);
    try testing.expectEqual(Error.Timeout, curlExitError(28, false).?);
    try testing.expectEqual(Error.TlsHandshakeFailed, curlExitError(35, false).?);
    try testing.expectEqual(Error.ProxyTunnelFailed, curlExitError(35, true).?);
    try testing.expectEqual(Error.CertificateInvalid, curlExitError(60, false).?);
    try testing.expect(curlExitError(22, false) == null); // HTTP 4xx 等不属于传输层
}

test "web：Content-Type 小写规范化（TEXT/HTML 也要命中 html 判定）" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("text/html", mimeLower(&buf, "TEXT/HTML; charset=utf-8"));
    try testing.expectEqualStrings("application/json", mimeLower(&buf, " Application/JSON "));
    try testing.expectEqualStrings("", mimeLower(&buf, ""));
    try testing.expect(std.mem.find(u8, mimeLower(&buf, "TEXT/HTML"), "html") != null);
}
