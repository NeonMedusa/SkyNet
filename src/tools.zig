const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const regex = @import("regex.zig");

// ── 工具定义（供模型调用的 JSON Schema）──

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

pub const tool_defs = [_]ToolDef{
    .{
        .name = "read",
        .description = "Read the contents of a file. Output is truncated to 2000 lines or 50KB (whichever is hit first). Each line is prefixed with its absolute line number as \"N: text\" (1-indexed); the number prefix is not part of the file content, so do not include it when matching text for edit. Use offset/limit for large files.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to read (relative or absolute)"},"offset":{"type":"integer","description":"Line number to start reading from (1-indexed)"},"limit":{"type":"integer","description":"Maximum number of lines to read"}},"required":["path"]}
        ,
    },
    .{
        .name = "write",
        .description = "Write content to a file. Creates the file if it doesn't exist, overwrites it if it does. Automatically creates parent directories.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to write (relative or absolute)"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "edit",
        .description = "Edit a single file using text replacement. Provide one or more edits in edits[]: each old_text must be unique in the ORIGINAL file and entries must not overlap. old_text is matched against the original file, not incrementally. Minor formatting differences (trailing/extra whitespace, indentation, backslash escaping) are tolerated automatically; the response notes when that happened. Still give enough context to be unambiguous, and extend old_text to the whole token/line you mean to change (a partial-token match that would split an identifier is refused). Prefer one call with several entries over several edit calls. Use write to create new files or fully rewrite a file.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to edit (relative or absolute)"},"edits":{"type":"array","description":"One or more targeted replacements. Each old_text is matched against the original file, not incrementally; entries must be unique and must not overlap. Keep old_text as small as possible while still unique, but cover the whole token/line you intend to change.","items":{"type":"object","properties":{"old_text":{"type":"string","description":"Text to replace (must be unique in the original file; minor whitespace/escaping differences are tolerated)"},"new_text":{"type":"string","description":"Replacement text for this entry"}},"required":["old_text","new_text"]}}},"required":["path","edits"]}
        ,
    },
    .{
        .name = "bash",
        .description = "Execute a shell command in the current working directory and return its output. On Windows this runs PowerShell (pwsh); on other platforms it runs sh. Output is truncated to the last 2000 lines or 50KB. Set timeout_ms to limit execution time.",
        .parameters =
        \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"},"timeout_ms":{"type":"integer","description":"Optional timeout in milliseconds"}},"required":["command"]}
        ,
    },
    .{
        .name = "grep",
        .description = "Search file contents for a pattern (regular expression by default; literal string when literal=true). Returns matching lines as path:line: text. Output is capped at limit matches (default 100) and 50KB.",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern (regular expression)"},"path":{"type":"string","description":"File or directory to search (default: current directory)"},"glob":{"type":"string","description":"Filter files by glob pattern, e.g. '*.zig' or 'src/**/*.zig'"},"context":{"type":"integer","description":"Number of context lines before/after each match (default 0)"},"limit":{"type":"integer","description":"Maximum number of matches (default 100)"},"ignore_case":{"type":"boolean","description":"Case-insensitive matching (default false)"},"literal":{"type":"boolean","description":"Treat pattern as a literal string instead of a regular expression"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "find",
        .description = "Find files by glob pattern, e.g. '*.zig', '**/*.json' or 'src/**/*.zig'. Returns paths relative to the search directory, one per line. Output is capped at limit results (default 1000) and 50KB.",
        .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern to match files"},"path":{"type":"string","description":"Directory to search (default: current directory)"},"limit":{"type":"integer","description":"Maximum number of results (default 1000)"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "ls",
        .description = "List directory contents sorted by name, with '/' suffix for directories. Set depth>0 to recurse (paths are then relative, directories keep the '/' suffix). Output is capped at limit entries (default 500) and 50KB.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default: current directory)"},"limit":{"type":"integer","description":"Maximum number of entries (default 500)"},"depth":{"type":"integer","description":"Recursion depth: 0 = current level only (default); N > 0 = recurse N levels"}}}
        ,
    },
};

pub const Result = struct {
    content: []u8,
    is_error: bool,
    /// 界面富文本（可选）：编辑工具生成的行号 diff，供 UI 着色渲染
    display: ?[]u8 = null,
};

// ── 限制 ──

const cap_lines = 2000;
const cap_bytes = 50 * 1024;
const max_read_bytes = 16 * 1024 * 1024;
const max_grep_file_bytes = 2 * 1024 * 1024;
const max_line_len = 500;

fn ok(allocator: Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Result {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = false };
}

fn fail(allocator: Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Result {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

fn resolvePath(allocator: Allocator, cwd: []const u8, p: []const u8) error{OutOfMemory}![]u8 {
    return std.fs.path.resolve(allocator, &.{ cwd, p });
}

fn isDir(io: Io, abs: []const u8) bool {
    var d = Dir.openDirAbsolute(io, abs, .{}) catch return false;
    d.close(io);
    return true;
}

fn fileExists(io: Io, abs: []const u8) bool {
    const f = Dir.openFileAbsolute(io, abs, .{}) catch return false;
    f.close(io);
    return true;
}

fn readFile(io: Io, allocator: Allocator, abs: []const u8, limit: usize) ![]u8 {
    const parent = std.fs.path.dirname(abs) orelse ".";
    var dir = try Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(abs), allocator, .limited(limit));
}

fn writeFileBytes(io: Io, abs: []const u8, data: []const u8) !void {
    const parent = std.fs.path.dirname(abs) orelse ".";
    makeDirs(io, parent);
    var dir = Dir.openDirAbsolute(io, parent, .{}) catch |err| {
        std.debug.print("openDirAbsolute err: {s} ({s})\n", .{ @errorName(err), parent });
        return err;
    };
    defer dir.close(io);
    const file = try dir.createFile(io, std.fs.path.basename(abs), .{ .truncate = true });
    defer file.close(io);
    file.writeStreamingAll(io, data) catch |err| {
        std.debug.print("writeStreamingAll err: {s}\n", .{@errorName(err)});
        return err;
    };
}

/// 递归创建目录（已存在则忽略）
fn makeDirs(io: Io, abs_dir: []const u8) void {
    if (abs_dir.len == 0) return;
    if (isDir(io, abs_dir)) return;
    if (std.fs.path.dirname(abs_dir)) |parent| {
        if (parent.len < abs_dir.len) makeDirs(io, parent);
    }
    Dir.createDirAbsolute(io, abs_dir, .default_dir) catch {};
}

// ── 输出截断 ──

const Cap = struct {
    text: []u8,
    notice: []u8,
};

fn finishCapped(allocator: Allocator, text: []u8, notice: []u8) error{OutOfMemory}![]u8 {
    if (notice.len == 0) return text;
    const out = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ text, notice });
    allocator.free(text);
    allocator.free(notice);
    return out;
}

fn countLines(data: []const u8) usize {
    if (data.len == 0) return 0;
    var total: usize = 0;
    var scan: usize = 0;
    while (scan < data.len) : (total += 1) {
        const nl = std.mem.indexOfScalarPos(u8, data, scan, '\n') orelse break;
        scan = nl + 1;
    }
    if (scan < data.len) total += 1;
    return total;
}

/// 给每行加绝对行号前缀（"N: 内容"，1 起）：便于模型引用位置与后续 edit 定位。
/// line_start 为 data 第一行的绝对行号；行尾换行原样保留，不新增/删除行。
fn numberLines(allocator: Allocator, data: []const u8, line_start: usize) error{OutOfMemory}![]u8 {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var line_no = line_start;
    while (i < data.len) : (line_no += 1) {
        const nl = std.mem.indexOfScalarPos(u8, data, i, '\n');
        const line_end = nl orelse data.len;
        var num_buf: [24]u8 = undefined;
        const prefix = std.fmt.bufPrint(&num_buf, "{d}: ", .{line_no}) catch unreachable;
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, data[i..line_end]);
        if (nl) |n| {
            try out.append(allocator, '\n');
            i = n + 1;
        } else {
            i = data.len;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// 头部截断：保留前面的完整行，超出部分丢弃。
/// line_base 为 data 第一行在文件中的绝对行号（1 起）。
fn capHead(allocator: Allocator, data: []const u8, max_lines: usize, max_bytes: usize, line_base: usize) error{OutOfMemory}!Cap {
    const total = countLines(data);
    var end: usize = 0;
    var lines: usize = 0;
    var by_bytes = false;
    var i: usize = 0;
    while (i <= data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, i, '\n');
        const line_end = nl orelse data.len;
        if (lines >= max_lines) break;
        if (line_end > max_bytes) {
            by_bytes = true;
            break;
        }
        end = line_end;
        lines += 1;
        if (nl == null) break;
        i = line_end + 1;
    }
    // 首行就超限：退化为按字节截断
    if (lines == 0 and data.len > 0) {
        end = utf8Boundary(data, @min(max_bytes, data.len));
        lines = 1;
        by_bytes = true;
    }
    const text = try allocator.dupe(u8, data[0..end]);
    if (end >= data.len) return .{ .text = text, .notice = "" };
    const total_abs = line_base + total -| 1;
    const start_abs = line_base;
    const end_abs = line_base + lines -| 1;
    const next_abs = line_base + lines;
    // 仅当确实存在下一行时才提示 offset：单行文件按字节截断时，
    // next_abs 会越过文件末尾，提示它会让模型读到 "Offset ... beyond end"。
    const has_next = next_abs <= total_abs;
    const notice = if (by_bytes and !has_next)
        try std.fmt.allocPrint(
            allocator,
            "[Line {d} exceeds the 50.0KB limit; showing its first 50.0KB. No further lines.]",
            .{start_abs},
        )
    else if (by_bytes)
        try std.fmt.allocPrint(
            allocator,
            "[Showing lines {d}-{d} of {d} (50.0KB limit). Use offset={d} to continue.]",
            .{ start_abs, end_abs, total_abs, next_abs },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]",
            .{ start_abs, end_abs, total_abs, next_abs },
        );
    return .{ .text = text, .notice = notice };
}

/// 尾部截断：保留最后的完整行（bash 输出用）
fn capTail(allocator: Allocator, data: []const u8, max_lines: usize, max_bytes: usize) error{OutOfMemory}!Cap {
    const total = countLines(data);
    var start: usize = data.len;
    var lines: usize = 0;
    var i: usize = data.len;
    while (true) {
        // 定位以 i 为结束位置的那一行的起点；i==0 表示已到数据开头，
        // 此时仍需处理 index 0 处的那一行（可能是前导空行），否则会漏计并误报截断。
        const line_start = if (i == 0) 0 else blk: {
            const head = data[0 .. i - 1];
            const prev_nl = std.mem.lastIndexOfScalar(u8, head, '\n');
            break :blk if (prev_nl) |n| n + 1 else 0;
        };
        if (lines >= max_lines or data.len - line_start > max_bytes) break;
        start = line_start;
        lines += 1;
        if (line_start == 0) break;
        i = line_start - 1;
    }
    if (lines == 0 and data.len > 0) {
        start = utf8BoundaryBack(data, data.len -| max_bytes);
    }
    const text = try allocator.dupe(u8, data[start..]);
    if (start == 0) return .{ .text = text, .notice = "" };
    // lines==0 时是"单行按字节截断"，仍属于最后一行，起始行号应为 total
    const shown_start = total -| (lines -| 1);
    const notice = try std.fmt.allocPrint(
        allocator,
        "[Showing lines {d}-{d} of {d}.]",
        .{ shown_start, total, total },
    );
    return .{ .text = text, .notice = notice };
}

fn utf8Boundary(data: []const u8, cut: usize) usize {
    var c = @min(cut, data.len);
    while (c > 0 and c < data.len and (data[c] & 0xC0) == 0x80) c -= 1;
    return c;
}

fn utf8BoundaryBack(data: []const u8, from: usize) usize {
    var c = @min(from, data.len);
    while (c > 0 and c < data.len and (data[c] & 0xC0) == 0x80) c -= 1;
    return c;
}

// ── 分发 ──

pub fn execute(allocator: Allocator, io: Io, cwd: []const u8, name: []const u8, args_json: []const u8) error{OutOfMemory}!Result {
    return executeWithEnv(allocator, io, cwd, name, args_json, null);
}

/// 带环境变量映射的版本（bash 截断时把全文写入系统临时目录需要 TEMP/TMPDIR）
pub fn executeWithEnv(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    name: []const u8,
    args_json: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}!Result {
    if (std.mem.eql(u8, name, "read")) return toolRead(allocator, io, cwd, args_json);
    if (std.mem.eql(u8, name, "write")) return toolWrite(allocator, io, cwd, args_json);
    if (std.mem.eql(u8, name, "edit")) return toolEdit(allocator, io, cwd, args_json);
    if (std.mem.eql(u8, name, "bash")) return toolBash(allocator, io, cwd, args_json, environ_map);
    if (std.mem.eql(u8, name, "grep")) return toolGrep(allocator, io, cwd, args_json);
    if (std.mem.eql(u8, name, "find")) return toolFind(allocator, io, cwd, args_json);
    if (std.mem.eql(u8, name, "ls")) return toolLs(allocator, io, cwd, args_json);
    return fail(allocator, "Unknown tool: {s}", .{name});
}

fn parseArgs(comptime T: type, allocator: Allocator, args_json: []const u8) ?T {
    // 注意：allocator 必须是 arena；解析结果由 arena 统一释放
    return std.json.parseFromSliceLeaky(T, allocator, args_json, .{ .ignore_unknown_fields = true }) catch null;
}

// ── read ──

const ReadArgs = struct {
    path: []const u8 = "",
    offset: i64 = 0,
    limit: i64 = 0,
};

fn toolRead(allocator: Allocator, io: Io, cwd: []const u8, args_json: []const u8) error{OutOfMemory}!Result {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = parseArgs(ReadArgs, args_arena.allocator(), args_json) orelse
        return fail(allocator, "Invalid arguments JSON for read", .{});
    if (args.path.len == 0) return fail(allocator, "Missing required parameter: path", .{});

    const abs = try resolvePath(allocator, cwd, args.path);
    defer allocator.free(abs);

    if (isDir(io, abs)) {
        return fail(allocator, "Path is a directory: {s}. Use ls to list directory contents.", .{args.path});
    }
    const data = readFile(io, allocator, abs, max_read_bytes) catch |err| switch (err) {
        error.FileNotFound => return fail(allocator, "File not found: {s}", .{args.path}),
        error.StreamTooLong => return fail(allocator, "File is too large to read: {s}", .{args.path}),
        else => return fail(allocator, "Could not read file {s}: {s}", .{ args.path, @errorName(err) }),
    };
    defer allocator.free(data);

    // 二进制文件：输出乱码只会浪费 token，直接说明并用 bash 兜底（与 grep 的 isBinary 一致）
    if (isBinary(data)) {
        return ok(allocator, "File appears to be binary ({d} bytes): {s}. Use bash (e.g. Get-Content/xxd) if you need its raw content.", .{ data.len, args.path });
    }
    // 空文件：显式说明，避免与"读取失败"混淆
    if (data.len == 0) {
        return ok(allocator, "(empty file: {s})", .{args.path});
    }

    const total_lines = countLines(data);
    const start_line: usize = if (args.offset > 1) @intCast(args.offset - 1) else 0;
    if (start_line >= total_lines and total_lines > 0) {
        return fail(allocator, "Offset {d} is beyond end of file ({d} lines total)", .{ args.offset, total_lines });
    }

    var pos: usize = 0;
    var skipped: usize = 0;
    while (skipped < start_line and pos < data.len) : (skipped += 1) {
        pos = (std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len - 1) + 1;
    }
    const sliced = data[@min(pos, data.len)..];
    // 行号前缀（绝对行号，与 offset 语义一致）：便于模型引用行号/后续 edit 定位
    const numbered = try numberLines(allocator, sliced, start_line + 1);
    defer allocator.free(numbered);

    const max_lines: usize = if (args.limit > 0) @intCast(args.limit) else cap_lines;
    const cap = try capHead(allocator, numbered, max_lines, cap_bytes, start_line + 1);
    return .{ .content = try finishCapped(allocator, cap.text, cap.notice), .is_error = false };
}

// ── edit 匹配失败的诊断 ──

/// 把文本按"忽略行尾空白"归一化（借鉴 pi 的 normalizeForFuzzyMatch，仅用于诊断）。
/// 返回归一化后的文本；调用者负责释放。失败时返回 null。
fn normalizeForDiag(allocator: Allocator, text: []const u8) ?[]u8 {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    var i: usize = 0;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const line_end = nl orelse text.len;
        var line = text[i..line_end];
        // 去掉行尾空白（空格/Tab/CR）
        while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t' or line[line.len - 1] == '\r')) {
            line = line[0 .. line.len - 1];
        }
        out.appendSlice(allocator, line) catch {
            out.deinit(allocator);
            return null;
        };
        if (nl != null) {
            out.append(allocator, '\n') catch {
                out.deinit(allocator);
                return null;
            };
            i = line_end + 1;
        } else break;
    }
    return out.toOwnedSlice(allocator) catch {
        out.deinit(allocator);
        return null;
    };
}

/// 诊断显示用的截断（按 UTF-8 边界，超长加 "..."）。失败返回空串。
fn truncForDiag(allocator: Allocator, line: []const u8, max: usize) []const u8 {
    if (line.len <= max) return allocator.dupe(u8, line) catch "";
    var cut = max;
    while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1; // 不切断 UTF-8 序列
    return std.fmt.allocPrint(allocator, "{s}...", .{line[0..cut]}) catch "";
}

/// 两行是否只有行首/行尾空白不同
fn onlyWhitespaceDiff(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, a, " \t\r"), std.mem.trim(u8, b, " \t\r"));
}

/// 把每个反斜杠连续段折叠成单个反斜杠（用于检测"转义层数"差异）
fn collapseBackslashRuns(allocator: Allocator, line: []const u8) ?[]u8 {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\\') {
            out.append(allocator, '\\') catch return null;
            while (i < line.len and line[i] == '\\') i += 1;
        } else {
            out.append(allocator, line[i]) catch return null;
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// 最长公共前缀长度（诊断用）
fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

/// 组装"期望 vs 实际"提示（含空白/反斜杠差异加注）
fn formatLineMismatch(
    allocator: Allocator,
    old_line: []const u8,
    file_line: []const u8,
    file_line_no: usize,
    eof: bool,
) []const u8 {
    const o_show = truncForDiag(allocator, old_line, 60);
    const d_show = truncForDiag(allocator, file_line, 60);
    var note: []const u8 = "";
    if (eof) {
        note = " (file ends before this line)";
    } else if (onlyWhitespaceDiff(old_line, file_line)) {
        note = " (differs only in leading/trailing whitespace)";
    } else if (collapseBackslashRuns(allocator, old_line)) |co| {
        defer allocator.free(co);
        if (collapseBackslashRuns(allocator, file_line)) |cd| {
            defer allocator.free(cd);
            if (std.mem.eql(u8, co, cd)) {
                note = std.fmt.allocPrint(
                    allocator,
                    " (backslash count differs: {d} vs {d} - watch JSON / multiline-string escaping)",
                    .{ std.mem.count(u8, old_line, "\\"), std.mem.count(u8, file_line, "\\") },
                ) catch "";
            }
        }
    }
    return std.fmt.allocPrint(
        allocator,
        " Hint: line {d} of the file does not match:\n" ++
            "   old_text: \"{s}\"\n" ++
            "   file:     \"{s}\"{s}",
        .{ file_line_no, o_show, d_show, note },
    ) catch "";
}

/// 从指定字节偏移取文件行的行号（1 起）
fn lineNoAt(data: []const u8, at: usize) usize {
    return std.mem.count(u8, data[0..@min(at, data.len)], "\n") + 1;
}

/// 两行的相似度（公共前缀 + 公共后缀，扣除重叠部分）——用于单行近似行定位
fn lineSimilarity(a: []const u8, b: []const u8) usize {
    const prefix = commonPrefixLen(a, b);
    if (prefix >= a.len or prefix >= b.len) return prefix;
    const ar = a[prefix..];
    const br = b[prefix..];
    const n = @min(ar.len, br.len);
    var suffix: usize = 0;
    while (suffix < n and ar[ar.len - 1 - suffix] == br[br.len - 1 - suffix]) suffix += 1;
    return prefix + suffix;
}

/// 统计从锚点之后、old 与 data 逐行完全相同的行数（用于多锚点择优）
fn countFollowingLineMatches(data: []const u8, old: []const u8, at: usize, old_first_nl: usize) usize {
    var oi: usize = old_first_nl + 1;
    var di: usize = blk: {
        const eol = std.mem.indexOfScalarPos(u8, data, at, '\n') orelse break :blk data.len;
        break :blk eol + 1;
    };
    var matched: usize = 0;
    while (oi < old.len and di < data.len) {
        const o_end = std.mem.indexOfScalarPos(u8, old, oi, '\n') orelse old.len;
        const d_end = std.mem.indexOfScalarPos(u8, data, di, '\n') orelse data.len;
        const o_line = std.mem.trimEnd(u8, old[oi..o_end], "\r");
        const d_line = std.mem.trimEnd(u8, data[di..d_end], "\r");
        if (!std.mem.eql(u8, o_line, d_line)) break;
        matched += 1;
        if (o_end >= old.len or d_end >= data.len) break;
        oi = o_end + 1;
        di = d_end + 1;
    }
    return matched;
}

/// 匹配失败时的行级诊断，两种模式：
/// A) 多行 old_text：以首行为锚点，从锚点后逐行比对，定位**第一个不一致的行**；
/// B) 单行 old_text：在文件各行的**最长公共前缀**里找最相近的一行（≥ 8 字节或
///    超过 old 的一半），展示"期望 vs 实际"——覆盖"转义层数/内部字符写错"这类
///    精确匹配失败（这是最常见的失败形态：反斜杠数量记错）。
/// 两类典型差异会加注：仅空白差异 → whitespace；仅反斜杠段数不同 → backslash count。
/// 锚点/近似行都找不到时返回空串（调用方回落到更粗的诊断）。
fn diagnoseLineMismatch(allocator: Allocator, data: []const u8, old: []const u8) []const u8 {
    const old_first_nl = std.mem.indexOfScalar(u8, old, '\n');
    const old_first_raw = if (old_first_nl) |n| old[0..n] else old;
    const old_first = std.mem.trimEnd(u8, old_first_raw, " \t\r");
    if (old_first.len < 4 or old_first.len > 400) return "";

    if (old_first_nl == null) {
        // B) 单行：找"最相近"的文件行（前缀 + 后缀匹配长度最大），覆盖
        //    "转义层数/内部字符写错"这类精确匹配失败。
        //    判据：相似度（前缀+后缀）至少覆盖 old 的一半，且至少 4 字节。
        var best_at: ?usize = null;
        var best_score: usize = 0;
        var li: usize = 0;
        while (li < data.len) {
            const le = std.mem.indexOfScalarPos(u8, data, li, '\n') orelse data.len;
            const line = std.mem.trimEnd(u8, data[li..le], "\r");
            const score = lineSimilarity(old_first, line);
            if (score > best_score) {
                best_score = score;
                best_at = li;
            }
            if (le >= data.len) break;
            li = le + 1;
        }
        if (best_at) |at| {
            const le = std.mem.indexOfScalarPos(u8, data, at, '\n') orelse data.len;
            const line = std.mem.trimEnd(u8, data[at..le], "\r");
            const min_score = @max(@as(usize, 4), old_first.len / 2);
            // 完全相等说明匹配得上的行存在（问题在别处），不在此诊断
            if (best_score >= min_score and !std.mem.eql(u8, old_first, line)) {
                return formatLineMismatch(allocator, old_first, line, lineNoAt(data, at), false);
            }
        }
        return "";
    }

    // A) 多行：首行为锚点。同一首行可能在文件中出现多次 → 逐个试，
    //    选“后续行匹配数最多”的那次（更可能是用户想改的那处）。
    var best_at: ?usize = null;
    var best_matched: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOf(u8, data[search_from..], old_first)) |rel| {
        const at = search_from + rel;
        const matched = countFollowingLineMatches(data, old, at, old_first_nl.?);
        if (best_at == null or matched > best_matched) {
            best_at = at;
            best_matched = matched;
        }
        if (matched == std.mem.count(u8, old, "\n")) break; // 全匹配：不可能更好
        search_from = at + 1;
        if (search_from >= data.len) break;
    }
    const at = best_at orelse return "";
    const anchor_line_no = lineNoAt(data, at);

    var oi: usize = old_first_nl.? + 1;
    var di: usize = blk: {
        const eol = std.mem.indexOfScalarPos(u8, data, at, '\n') orelse break :blk data.len;
        break :blk eol + 1;
    };
    var old_line_no: usize = 1;
    var file_line_no: usize = anchor_line_no;
    var hint: []const u8 = "";
    while (oi < old.len) {
        old_line_no += 1;
        file_line_no += 1;
        const o_end = std.mem.indexOfScalarPos(u8, old, oi, '\n') orelse old.len;
        const eof = di >= data.len;
        const d_end = if (!eof)
            (std.mem.indexOfScalarPos(u8, data, di, '\n') orelse data.len)
        else
            data.len;
        const o_line = std.mem.trimEnd(u8, old[oi..o_end], "\r");
        const d_line = if (!eof) std.mem.trimEnd(u8, data[di..d_end], "\r") else "";
        if (!std.mem.eql(u8, o_line, d_line)) {
            hint = std.fmt.allocPrint(
                allocator,
                "{s}\n   (multi-line old_text: line {d} of it)",
                .{ formatLineMismatch(allocator, o_line, d_line, file_line_no, eof), old_line_no },
            ) catch "";
            return hint;
        }
        if (o_end >= old.len) break;
        oi = o_end + 1;
        di = if (eof) data.len + 1 else d_end + 1;
    }
    return "";
}

fn diagnoseEditMiss(allocator: Allocator, data: []const u8, old: []const u8) []const u8 {
    // 1) 归一化（去行尾空白）后能否匹配？→ 提示行尾空白差异（最直白，优先）
    if (normalizeForDiag(allocator, data)) |nd| {
        defer allocator.free(nd);
        if (normalizeForDiag(allocator, old)) |no| {
            defer allocator.free(no);
            if (no.len > 0 and std.mem.indexOf(u8, nd, no) != null) {
                return std.fmt.allocPrint(
                    allocator,
                    " Hint: a match exists if trailing whitespace is ignored - check for trailing spaces, tabs, or line-ending (CRLF/LF) differences.",
                    .{},
                ) catch "";
            }
        }
    }

    // 2) 多行：逐行比对，定位第一个不一致的行（比"首行位置"具体得多）
    const line_hint = diagnoseLineMismatch(allocator, data, old);
    if (line_hint.len > 0) return line_hint;

    // 3) old_string 首行（trim 后）在文件中的位置 → 提示近似位置
    const first_nl = std.mem.indexOfScalar(u8, old, '\n');
    const first_raw = if (first_nl) |n| old[0..n] else old;
    const first = std.mem.trim(u8, first_raw, " \t\r");
    if (first.len >= 4 and first.len <= 200) {
        if (std.mem.indexOf(u8, data, first)) |at| {
            const line_no = std.mem.count(u8, data[0..at], "\n") + 1;
            return std.fmt.allocPrint(
                allocator,
                " Hint: the first line of old_text appears at line {d} - compare the surrounding text there.",
                .{line_no},
            ) catch "";
        }
    }
    return "";
}

// ── write ──

const WriteArgs = struct {
    path: []const u8 = "",
    content: []const u8 = "",
};

fn toolWrite(allocator: Allocator, io: Io, cwd: []const u8, args_json: []const u8) error{OutOfMemory}!Result {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = parseArgs(WriteArgs, args_arena.allocator(), args_json) orelse
        return fail(allocator, "Invalid arguments JSON for write", .{});
    if (args.path.len == 0) return fail(allocator, "Missing required parameter: path", .{});

    const abs = try resolvePath(allocator, cwd, args.path);
    defer allocator.free(abs);

    if (isDir(io, abs)) {
        return fail(allocator, "Path is a directory, not a file: {s}", .{args.path});
    }

    writeFileBytes(io, abs, args.content) catch |err| {
        return fail(allocator, "Could not write file {s}: {s}", .{ args.path, @errorName(err) });
    };
    return ok(allocator, "Successfully wrote to {s} ({d} bytes)", .{ args.path, args.content.len });
}

// ── edit ──

/// 单条编辑项（edits[] 的元素）
const EditItem = struct {
    old_text: []const u8 = "",
    new_text: []const u8 = "",
};

/// edit 工具参数。schema 只暴露 path + edits[]（仿 pi：统一一种写法，
/// 单处也用数组——避免模型在"用哪个"上犹豫/选错）。
const EditArgs = struct {
    path: []const u8 = "",
    edits: []const EditItem = &.{},
};

/// 容错：把非规范输入归一化为 EditArgs。
/// 支持：① 标准 {"path","edits":[{old_text,new_text}]}；
///       ② edits 传成单个对象而非数组（`{"edits":{...}}` → 单元素数组）。
/// 不兼容其他 agent 的字段命名（如 pi 的驼峰 oldText/newText）——该设想及其
/// 争议见 docs/development.md 2.5「未来可讨论的点：跨 agent 工具字段兼容」。
fn prepareEditArgs(allocator: Allocator, args_json: []const u8) ?EditArgs {
    // ① 标准形式
    if (parseArgs(EditArgs, allocator, args_json)) |a| {
        if (a.edits.len > 0) return a;
        // edits 为空数组或缺失 → 继续尝试 ②
        return prepareEditArgsFallback(allocator, args_json) orelse return a;
    }
    // ② edits 单对象
    return prepareEditArgsFallback(allocator, args_json);
}

fn prepareEditArgsFallback(allocator: Allocator, args_json: []const u8) ?EditArgs {
    const Loose = struct {
        path: []const u8 = "",
        /// edits 传成单个对象（而非数组）时的容错
        edits: ?EditItem = null,
    };
    const loose = parseArgs(Loose, allocator, args_json) orelse return null;
    if (loose.edits) |item| {
        const list = allocator.alloc(EditItem, 1) catch return null;
        list[0] = item;
        return .{ .path = loose.path, .edits = list };
    }
    return null;
}

fn toolEdit(allocator: Allocator, io: Io, cwd: []const u8, args_json: []const u8) error{OutOfMemory}!Result {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = prepareEditArgs(args_arena.allocator(), args_json) orelse
        return fail(allocator, "Invalid arguments JSON for edit", .{});

    if (args.path.len == 0) return fail(allocator, "Missing required parameter: path", .{});
    if (args.edits.len == 0) {
        return fail(allocator, "Missing required parameter: edits[]. Each entry needs old_text (exact, unique in the file) and new_text. Use write to create files or rewrite them completely.", .{});
    }

    const abs = try resolvePath(allocator, cwd, args.path);
    defer allocator.free(abs);

    if (isDir(io, abs)) {
        return fail(allocator, "Path is a directory, not a file: {s}", .{args.path});
    }
    const data = readFile(io, allocator, abs, max_read_bytes) catch |err| switch (err) {
        error.FileNotFound => return fail(allocator, "File not found: {s}", .{args.path}),
        error.StreamTooLong => return fail(allocator, "File is too large to edit: {s}", .{args.path}),
        else => return fail(allocator, "Could not read file {s}: {s}", .{ args.path, @errorName(err) }),
    };
    defer allocator.free(data);

    return toolEditMulti(allocator, io, abs, args.path, data, args.edits);
}

/// 容错匹配结果：命中的原始区间 + 生效的放宽级别
const LooseMatch = struct {
    start: usize,
    len: usize,
    /// 0=精确 1=行尾空白 2=空白归一 3=缩进弹性 4=转义归一
    level: u8,
};

/// 放宽级别名（成功消息短标记用；0=精确不显示）
fn looseLevelName(level: u8) []const u8 {
    return switch (level) {
        1 => "trailing-whitespace",
        2 => "whitespace-insensitive",
        3 => "indentation-flexible",
        4 => "escape-normalized",
        else => "",
    };
}

/// 归一化级别（各变换都**保持 '\n' 不变**，只改行内/连续字符）
const LooseKind = enum { tail_ws, inner_ws, escape, indent };

/// 归一化并记录偏移映射：norm[i] 的源字节在原始文本中的偏移（map 长 = norm.len + 1）。
/// 被丢弃的字节（如行尾空白）不占输出；被折叠的连续段共享首字节偏移。
/// 返回 null = 分配失败。
const NormMapped = struct { norm: []u8, map: []usize };
fn normalizeWithMap(allocator: Allocator, text: []const u8, kind: LooseKind) ?NormMapped {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer out.deinit(allocator);
    var map = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
    defer map.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (kind) {
            .tail_ws => {
                if (c == '\n') {
                    // 行尾：跳过本行末尾的空白
                    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t' or out.items[out.items.len - 1] == '\r')) {
                        _ = out.pop();
                        _ = map.pop();
                    }
                    out.append(allocator, '\n') catch return null;
                    map.append(allocator, i) catch return null;
                    i += 1;
                } else {
                    out.append(allocator, c) catch return null;
                    map.append(allocator, i) catch return null;
                    i += 1;
                }
            },
            .inner_ws => {
                if (c == ' ' or c == '\t') {
                    out.append(allocator, ' ') catch return null;
                    map.append(allocator, i) catch return null;
                    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                } else {
                    out.append(allocator, c) catch return null;
                    map.append(allocator, i) catch return null;
                    i += 1;
                }
            },
            .escape => {
                if (c == '\\') {
                    out.append(allocator, '\\') catch return null;
                    map.append(allocator, i) catch return null;
                    while (i < text.len and text[i] == '\\') i += 1;
                } else {
                    out.append(allocator, c) catch return null;
                    map.append(allocator, i) catch return null;
                    i += 1;
                }
            },
            .indent => {
                // 文本开头（i == 0）与每个 '\n' 之后都是"行首"：跳过行首空白
                if (i == 0 or text[i - 1] == '\n') {
                    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                }
                if (i >= text.len) break;
                out.append(allocator, text[i]) catch return null;
                map.append(allocator, i) catch return null;
                i += 1;
            },
        }
    }
    map.append(allocator, text.len) catch return null; // 末尾哨兵
    return .{
        .norm = out.toOwnedSlice(allocator) catch return null,
        .map = map.toOwnedSlice(allocator) catch return null,
    };
}

/// 行锚定校验：匹配区间 [s0, s1) 的两侧到行边界之间**只能有空白**。
/// 放宽匹配的危险形态是"行中间的部分子串命中"——例如文件行 `\\ TABLE x (`
/// （两个反斜杠）与 old `\ TABLE x (`（一个反斜杠）能匹配后半段，
/// 但替换区间从第二个反斜杠开始，残留的第一个反斜杠会与新文本拼接成垃圾。
/// 正常意图（整行/行首对齐的内容）两侧到行边界都是空白或直接是边界。
fn lineAnchored(data: []const u8, s0: usize, s1: usize) bool {
    // 起点向左到行首：途中字节必须全是空白
    var i: usize = s0;
    while (i > 0 and data[i - 1] != '\n') {
        i -= 1;
        if (data[i] != ' ' and data[i] != '\t' and data[i] != '\r') return false;
    }
    // 终点向右到行尾：途中字节必须全是空白
    var j: usize = s1;
    while (j < data.len and data[j] != '\n') {
        if (data[j] != ' ' and data[j] != '\t' and data[j] != '\r') return false;
        j += 1;
    }
    return true;
}

/// 单级宽松匹配：归一化双方 → 唯一命中 → 用偏移映射反推原始区间。
/// 返回 null = 本级别不适用（不命中/多处命中/映射退化）。
fn matchAtLevel(allocator: Allocator, data: []const u8, old: []const u8, kind: LooseKind) ?struct { start: usize, len: usize } {
    const nd = normalizeWithMap(allocator, data, kind) orelse return null;
    defer allocator.free(nd.norm);
    defer allocator.free(nd.map);
    const no = normalizeWithMap(allocator, old, kind) orelse return null;
    defer allocator.free(no.norm);
    defer allocator.free(no.map);
    if (no.norm.len == 0) return null;

    const at = std.mem.indexOf(u8, nd.norm, no.norm) orelse {
        return null;
    };
    if (std.mem.indexOfPos(u8, nd.norm, at + 1, no.norm) != null) {
        return null;
    }

    const s0 = nd.map[at];
    const s1 = nd.map[at + no.norm.len];
    if (s1 <= s0) {
        return null;
    }
    // 校验：映射出的原始区间重新归一化后应等于 no.norm（防映射退化/跨界）
    const check = normalizeWithMap(allocator, data[s0..s1], kind) orelse return null;
    defer allocator.free(check.norm);
    defer allocator.free(check.map);
    if (!std.mem.eql(u8, check.norm, no.norm)) {
        return null;
    }
    // 行锚定：拒绝"行中间的部分子串命中"（见 lineAnchored 注释）
    if (!lineAnchored(data, s0, s1)) return null;
    return .{ .start = s0, .len = s1 - s0 };
}

/// 在 data 中查找 old 的宽松匹配：精确优先，失败则逐级放宽（每级要求唯一命中）。
/// 返回 null 表示所有级别都失败（调用方走诊断报错）。
fn looseFind(allocator: Allocator, data: []const u8, old: []const u8) ?LooseMatch {
    // 精确
    if (std.mem.indexOf(u8, data, old)) |at| {
        if (std.mem.indexOfPos(u8, data, at + 1, old) == null) {
            return .{ .start = at, .len = old.len, .level = 0 };
        }
        return null; // 精确但多处：交给调用方报"不唯一"（语义更清晰）
    }
    // 顺序从严到宽（对齐 opencode）：行尾空白 → 内部空白 → 行首缩进 → 反斜杠转义。
    // escape 最激进（把 \\ 与 \ 视为等价），放最后。
    const kinds = [_]LooseKind{ .tail_ws, .inner_ws, .indent, .escape };
    const levels = [_]u8{ 1, 2, 3, 4 };
    for (kinds, levels) |k, lv| {
        if (matchAtLevel(allocator, data, old, k)) |m| {
            return .{ .start = m.start, .len = m.len, .level = lv };
        }
    }
    return null;
}

/// 是否为标识符字符（用于"替换边界切开标识符"警告）
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// 替换边界是否切开标识符：匹配区间紧邻的字符与替换文本拼接后"粘连"。
/// 例：文件 "id INTEGER"，old "id INT"（子串命中），new "id BIG" →
/// 尾部残留 "EGER" 会与新文本末字符粘成新标识符 → 警告。
fn boundarySplitsIdentifier(data: []const u8, start: usize, old_len: usize, new_text: []const u8) bool {
    const end = start + old_len;
    if (old_len == 0) return false;
    // 尾部粘连
    const old_tail_ident = isIdentChar(data[end - 1]);
    const after_ident = end < data.len and isIdentChar(data[end]);
    const new_tail_ident = new_text.len > 0 and isIdentChar(new_text[new_text.len - 1]);
    if (old_tail_ident and after_ident and new_tail_ident) return true;
    // 头部粘连
    const before_ident = start > 0 and isIdentChar(data[start - 1]);
    const old_head_ident = isIdentChar(data[start]);
    const new_head_ident = new_text.len > 0 and isIdentChar(new_text[0]);
    if (before_ident and old_head_ident and new_head_ident) return true;
    return false;
}

/// 过大匹配拒绝（opencode isDisproportionateMatch 的简化版）：
/// 匹配区间远大于 old_text 时拒绝，避免"锚到一大段无关内容"。
fn isDisproportionate(search_len: usize, old_len: usize) bool {
    if (old_len == 0) return false;
    return search_len >= old_len * 4 and search_len >= old_len + 500;
}

/// 多处编辑（edits[]）：每个 old_text 匹配**原始文件**，互不重叠，一次写回。
/// 语义（仿 pi）：全部匹配成功才应用（全有或全无）；任一不匹配/不唯一/重叠即报错。
fn toolEditMulti(
    allocator: Allocator,
    io: Io,
    abs: []const u8,
    path: []const u8,
    data: []const u8,
    edits: []const EditItem,
) error{OutOfMemory}!Result {
    // 诊断文本等临时分配（随函数结束整体释放，避免泄漏）
    var diag_arena = std.heap.ArenaAllocator.init(allocator);
    defer diag_arena.deinit();

    const Applied = struct { start: usize, old_len: usize, new_text: []const u8, idx: usize };
    var applied = std.ArrayListUnmanaged(Applied){ .items = &.{}, .capacity = 0 };
    defer applied.deinit(allocator);

    // CRLF 文件 + LF old_text 的适配（与旧单编辑路径行为一致）：
    // 若 data 含 CRLF 且某条 old_text 是 LF 形式，先转成 CRLF 再匹配
    const data_is_crlf = std.mem.indexOf(u8, data, "\r\n") != null;
    var converted = std.ArrayListUnmanaged([]u8){ .items = &.{}, .capacity = 0 };
    defer {
        for (converted.items) |c| allocator.free(c);
        converted.deinit(allocator);
    }

    // 放宽级别使用记录（成功消息里给一行短标记；0 = 精确，不显示）
    var loose_levels = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer loose_levels.deinit(allocator);

    for (edits, 0..) |item, i| {
        if (item.old_text.len == 0) {
            return fail(allocator, "edits[{d}].old_text must not be empty.", .{i});
        }
        var old_text = item.old_text;
        var new_text = item.new_text;
        var occurrences = std.mem.count(u8, data, old_text);
        if (occurrences == 0 and data_is_crlf and std.mem.indexOfScalar(u8, old_text, '\r') == null) {
            const dos_old = crlf(allocator, old_text) catch null;
            if (dos_old) |d| {
                try converted.append(allocator, d);
                const dos_new = crlf(allocator, new_text) catch null;
                if (dos_new) |n| try converted.append(allocator, n);
                const count = std.mem.count(u8, data, d);
                if (count > 0) {
                    old_text = d;
                    new_text = if (dos_new) |n| n else new_text;
                    occurrences = count;
                }
            }
        }

        if (occurrences == 1) {
            // 精确命中（唯一）：仍要过"边界切开标识符"检查——
            // 子串语义下 "value INT" 能命中 "value INTEGER"，会把残留粘成新标识符。
            const at = std.mem.indexOf(u8, data, old_text).?;
            if (boundarySplitsIdentifier(data, at, old_text.len, new_text)) {
                return fail(allocator, "edits[{d}]: refusing replacement: the boundary splits an identifier in {s} (the text right after the match would merge with new_text). Extend old_text to cover the whole token/line you meant to change.", .{ i, path });
            }
            try applied.append(allocator, .{ .start = at, .old_len = old_text.len, .new_text = new_text, .idx = i });
            try loose_levels.append(allocator, 0);
            continue;
        }
        if (occurrences > 1) {
            return fail(allocator, "edits[{d}]: found {d} occurrences of the text in {s}. It must be unique — add surrounding context.", .{ i, occurrences, path });
        }

        // 精确失败 → 分级放宽（每级要求唯一命中）
        if (looseFind(diag_arena.allocator(), data, item.old_text)) |m| {
            if (isDisproportionate(m.len, item.old_text.len)) {
                return fail(allocator, "edits[{d}]: refusing replacement: the matched span ({d} bytes) is much larger than old_text ({d} bytes). Re-read the file and give the exact text you intend to replace.", .{ i, m.len, item.old_text.len });
            }
            if (boundarySplitsIdentifier(data, m.start, m.len, new_text)) {
                return fail(allocator, "edits[{d}]: refusing replacement: the boundary splits an identifier in {s} (the text right after the match would merge with new_text). Check that old_text covers the whole token/line you meant to change.", .{ i, path });
            }
            try applied.append(allocator, .{ .start = m.start, .old_len = m.len, .new_text = new_text, .idx = i });
            try loose_levels.append(allocator, m.level);
            continue;
        }

        // 全部失败：诊断线索（arena 分配，随本次调用结束释放）
        const hint = diagnoseEditMiss(diag_arena.allocator(), data, item.old_text);
        return fail(allocator, "edits[{d}]: could not find the exact text in {s}. It must match exactly including whitespace and newlines.{s}", .{ i, path, hint });
    }

    // 重叠检查：按起点排序后，前一个的区间不得越过当前的起点
    std.mem.sort(Applied, applied.items, {}, struct {
        fn lt(_: void, a: Applied, b: Applied) bool {
            return a.start < b.start;
        }
    }.lt);
    for (applied.items, 0..) |a, i| {
        if (i == 0) continue;
        const prev = applied.items[i - 1];
        if (prev.start + prev.old_len > a.start) {
            return fail(allocator, "edits[{d}] and edits[{d}] overlap in {s}. Merge them into one edit or target disjoint regions.", .{ prev.idx, a.idx, path });
        }
    }

    // 应用：按位置顺序拼接（已排序，直接一次遍历）
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer out.deinit(allocator);
    var cursor: usize = 0;
    for (applied.items) |a| {
        try out.appendSlice(allocator, data[cursor..a.start]);
        try out.appendSlice(allocator, a.new_text);
        cursor = a.start + a.old_len;
    }
    try out.appendSlice(allocator, data[cursor..]);

    if (std.mem.eql(u8, out.items, data)) {
        return fail(allocator, "No changes made to {s}: the edits produced identical content.", .{path});
    }

    writeFileBytes(io, abs, out.items) catch |err| {
        return fail(allocator, "Could not write file {s}: {s}", .{ path, @errorName(err) });
    };
    const display = buildEditDiff(allocator, data, out.items) catch null;
    // 放宽标记：仅当有编辑走了非精确匹配时附一行短标记（正常路径零额外输出）。
    // 同一级别多次出现时合并为 "name×N"，避免重复占 token。
    var loose_note = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer loose_note.deinit(allocator);
    {
        // 统计各放宽级别出现次数（下标 = 级别；0 精确不记）
        var counts = [_]usize{0} ** 5;
        for (loose_levels.items) |lv| {
            if (lv > 0 and lv < counts.len) counts[lv] += 1;
        }
        for (counts, 0..) |n, lv| {
            if (n == 0) continue;
            const name = looseLevelName(@intCast(lv));
            if (name.len == 0) continue;
            if (loose_note.items.len == 0) {
                try loose_note.appendSlice(allocator, " (matched loosely: ");
            } else {
                try loose_note.appendSlice(allocator, ", ");
            }
            if (n > 1) {
                const part = try std.fmt.allocPrint(allocator, "{s}x{d}", .{ name, n });
                defer allocator.free(part);
                try loose_note.appendSlice(allocator, part);
            } else {
                try loose_note.appendSlice(allocator, name);
            }
        }
        if (loose_note.items.len > 0) try loose_note.appendSlice(allocator, ")");
    }
    return .{
        .content = try std.fmt.allocPrint(allocator, "Successfully applied {d} edit{s} in {s}.{s}", .{ edits.len, if (edits.len == 1) "" else "s", path, loose_note.items }),
        .is_error = false,
        .display = display,
    };
}

fn crlf(allocator: Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    for (text) |c| {
        if (c == '\n') try out.append(allocator, '\r');
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

// ── edit diff 展示 ──

const diff_context_lines = 3;
const diff_max_lines = 40;

/// 按 '\n' 切分（保留空行），去掉行尾 \r
fn splitPlainLines(allocator: Allocator, text: []const u8, list: *std.ArrayListUnmanaged([]const u8)) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const end = nl orelse text.len;
        var line = text[i..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try list.append(allocator, line);
        if (nl == null) break;
        i = end + 1;
    }
}

fn appendNumberedLine(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    line_no: usize,
    marker: u8,
    text: []const u8,
) error{OutOfMemory}!void {
    var buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{d:>5} {c} ", .{ line_no, marker }) catch "     ? ";
    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, text);
    try out.append(allocator, '\n');
}

fn appendDiffElide(allocator: Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try out.appendSlice(allocator, "     …\n");
}

/// 生成行号 diff 展示文本（上下文 3 行；`-` 删除 / `+` 新增）
fn buildEditDiff(allocator: Allocator, old_text: []const u8, new_text: []const u8) error{OutOfMemory}![]u8 {
    var old_lines = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
    defer old_lines.deinit(allocator);
    var new_lines = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
    defer new_lines.deinit(allocator);
    try splitPlainLines(allocator, old_text, &old_lines);
    try splitPlainLines(allocator, new_text, &new_lines);

    // 行级公共前缀 / 后缀
    var prefix: usize = 0;
    while (prefix < old_lines.items.len and prefix < new_lines.items.len and
        std.mem.eql(u8, old_lines.items[prefix], new_lines.items[prefix])) : (prefix += 1)
    {}
    var suffix: usize = 0;
    while (suffix < old_lines.items.len - prefix and suffix < new_lines.items.len - prefix and
        std.mem.eql(u8, old_lines.items[old_lines.items.len - 1 - suffix], new_lines.items[new_lines.items.len - 1 - suffix])) : (suffix += 1)
    {}

    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var line_count: usize = 0;
    var truncated = false;

    // 前缀上下文
    const ctx_start = if (prefix > diff_context_lines) prefix - diff_context_lines else 0;
    if (ctx_start > 0) {
        try appendDiffElide(allocator, &out);
        line_count += 1;
    }
    var i = ctx_start;
    while (i < prefix) : (i += 1) {
        try appendNumberedLine(allocator, &out, i + 1, ' ', old_lines.items[i]);
        line_count += 1;
    }

    // 删除行（旧行号）/ 新增行（新行号）
    // 预算不足时两侧各分一半，保证 `-` 与 `+` 都出现；否则大改动会先耗尽
    // 预算、只显示删除行，看起来像把内容删掉了。
    const removed_end = old_lines.items.len - suffix;
    const added_end = new_lines.items.len - suffix;
    const removed_count = removed_end - prefix;
    const added_count = added_end - prefix;
    const budget = diff_max_lines -| line_count;

    var show_removed = removed_count;
    var show_added = added_count;
    if (removed_count + added_count > budget) {
        if (removed_count == 0) {
            show_added = @min(budget, added_count);
        } else if (added_count == 0) {
            show_removed = @min(budget, removed_count);
        } else {
            show_removed = @min(@max(budget / 2, 1), removed_count);
            show_added = @min(budget -| show_removed, added_count);
        }
    }

    i = prefix;
    var shown: usize = 0;
    while (i < removed_end and shown < show_removed) : ({
        i += 1;
        shown += 1;
    }) {
        try appendNumberedLine(allocator, &out, i + 1, '-', old_lines.items[i]);
        line_count += 1;
    }
    if (shown < removed_count) {
        truncated = true;
        try appendDiffElide(allocator, &out);
    }

    i = prefix;
    shown = 0;
    while (i < added_end and shown < show_added) : ({
        i += 1;
        shown += 1;
    }) {
        try appendNumberedLine(allocator, &out, i + 1, '+', new_lines.items[i]);
        line_count += 1;
    }
    if (shown < added_count) {
        truncated = true;
        try appendDiffElide(allocator, &out);
    }

    // 后缀上下文（新行号）
    if (!truncated) {
        const suffix_show = @min(suffix, diff_context_lines);
        i = 0;
        while (i < suffix_show) : (i += 1) {
            const line_index = new_lines.items.len - suffix + i;
            try appendNumberedLine(allocator, &out, line_index + 1, ' ', new_lines.items[line_index]);
            line_count += 1;
        }
        if (suffix > diff_context_lines) try appendDiffElide(allocator, &out);
    }

    // 去掉末尾换行
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(allocator);
}

// ── bash ──

const BashArgs = struct {
    command: []const u8 = "",
    timeout_ms: i64 = 0,
};

/// Windows 上 pwsh 默认按控制台代码页（如中文 GB2312）写输出，
/// 重定向到管道后字节仍是 GBK，模型会看到乱码。
/// 修复：执行前把控制台输出编码切到 UTF-8。
const pwsh_utf8_prefix = "try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}\n";

/// 去除 ANSI 转义序列（CSI/OSC/双字符转义）：颜色码进入历史纯属浪费 token
fn stripAnsiAlloc(allocator: Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, data.len);

    var i: usize = 0;
    while (i < data.len) {
        const c = data[i];
        if (c != 0x1B) {
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (i + 1 >= data.len) break; // 孤立 ESC：丢弃
        const next = data[i + 1];
        if (next == '[') {
            // CSI：参数/中间字节后跟 0x40-0x7E 终止字节
            i += 2;
            while (i < data.len) : (i += 1) {
                const b = data[i];
                if (b >= 0x40 and b <= 0x7E) {
                    i += 1;
                    break;
                }
            }
        } else if (next == ']') {
            // OSC：终止于 BEL 或 ST(ESC \)
            i += 2;
            while (i < data.len) : (i += 1) {
                if (data[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (data[i] == 0x1B and i + 1 < data.len and data[i + 1] == '\\') {
                    i += 2;
                    break;
                }
            }
        } else if (next >= 0x40 and next <= 0x5F) {
            i += 2; // 双字符转义
        } else if (next >= 0x20 and next <= 0x2F) {
            i += 2;
            while (i < data.len and data[i] >= 0x30 and data[i] <= 0x7E) i += 1; // 中间字节
        } else {
            i += 1; // 丢弃 ESC
        }
    }
    return out.toOwnedSlice(allocator);
}

fn toolBash(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    args_json: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) error{OutOfMemory}!Result {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = parseArgs(BashArgs, args_arena.allocator(), args_json) orelse
        return fail(allocator, "Invalid arguments JSON for bash", .{});
    if (args.command.len == 0) return fail(allocator, "Missing required parameter: command", .{});

    const is_windows = @import("builtin").os.tag == .windows;
    const full_command: []const u8 = if (is_windows)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ pwsh_utf8_prefix, args.command })
    else
        args.command;
    defer if (is_windows) allocator.free(full_command);

    const argv: []const []const u8 = if (is_windows)
        &.{ "pwsh.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", full_command }
    else
        &.{ "sh", "-c", full_command };

    const timeout: Io.Timeout = if (args.timeout_ms > 0)
        .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(args.timeout_ms), .clock = .awake } }
    else
        .none;

    const run_result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .timeout = timeout,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .reserve_amount = 8192,
    }) catch |err| switch (err) {
        error.Timeout => return fail(allocator, "Command timed out after {d} ms", .{args.timeout_ms}),
        error.StreamTooLong => return fail(allocator, "Command output exceeded the limit (4MB)", .{}),
        else => return fail(allocator, "Failed to run command: {s}", .{@errorName(err)}),
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    var combined = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer combined.deinit(allocator);
    try combined.appendSlice(allocator, run_result.stdout);
    if (run_result.stderr.len > 0) {
        if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n') {
            try combined.append(allocator, '\n');
        }
        try combined.appendSlice(allocator, run_result.stderr);
    }

    // 统一为 LF（PowerShell 输出 CRLF），并去掉裸 \r（进度条残留）
    var normalized = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    defer normalized.deinit(allocator);
    {
        var idx: usize = 0;
        while (idx < combined.items.len) : (idx += 1) {
            const c = combined.items[idx];
            if (c == '\r') continue;
            try normalized.append(allocator, c);
        }
    }

    // 去掉 ANSI 颜色/控制序列（模型不需要，纯浪费 token）
    const stripped = try stripAnsiAlloc(allocator, normalized.items);
    defer allocator.free(stripped);

    var cap = try capTail(allocator, stripped, cap_lines, cap_bytes);
    if (cap.text.len == 0) {
        allocator.free(cap.text);
        cap.text = try allocator.dupe(u8, "(no output)");
    }

    // 截断时把全文写入系统临时文件，并在提示里给出路径：
    // 模型需要被截掉的部分时可以直接 read，而不是重跑命令（pi / opencode 同款兜底）
    if (cap.notice.len > 0) {
        if (try persistBashFullOutput(allocator, io, environ_map, stripped)) |path| {
            defer allocator.free(path);
            const amended = try std.fmt.allocPrint(
                allocator,
                "{s}\nFull output saved to: {s}",
                .{ cap.notice, path },
            );
            allocator.free(cap.notice);
            cap.notice = amended;
        }
    }

    var exit_note: ?[]u8 = null;
    defer if (exit_note) |n| allocator.free(n);
    switch (run_result.term) {
        .exited => |code| {
            if (code != 0) {
                exit_note = try std.fmt.allocPrint(allocator, "Command exited with code {d}", .{code});
            }
        },
        else => {
            exit_note = try std.fmt.allocPrint(allocator, "Command terminated abnormally: {any}", .{run_result.term});
        },
    }

    if (exit_note) |note| {
        const with_note = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ cap.text, note });
        allocator.free(cap.text);
        cap.text = with_note;
    }
    return .{ .content = try finishCapped(allocator, cap.text, cap.notice), .is_error = false };
}

/// bash 截断全文落盘用的自增序号（同一毫秒内多次截断时避免重名）。
/// 仅由 agent worker 线程访问（工具执行单线程）；若未来多线程并行调工具需改为原子。
var bash_temp_seq: u32 = 0;

/// bash 临时文件所在目录（TEMP/TMPDIR/TMP；缺失返回 null）
fn bashTempDir(environ_map: ?*const std.process.Environ.Map) ?[]const u8 {
    const map = environ_map orelse return null;
    const dir = map.get("TEMP") orelse map.get("TMPDIR") orelse map.get("TMP") orelse return null;
    return if (dir.len > 0) dir else null;
}

/// 把被截断的 bash 全文写入系统临时目录（TEMP/TMPDIR/TMP）。
/// 返回分配的路径；环境变量缺失或写入失败时返回 null（调用方保留原提示）。
fn persistBashFullOutput(
    allocator: Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    data: []const u8,
) error{OutOfMemory}!?[]u8 {
    const dir = bashTempDir(environ_map) orelse return null;

    var name_buf: [80]u8 = undefined;
    const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
    bash_temp_seq +%= 1;
    const name = std.fmt.bufPrint(&name_buf, "skynet-bash-{d}-{d}.txt", .{ now_ms, bash_temp_seq }) catch return null;
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    errdefer allocator.free(path);

    const parent = std.fs.path.dirname(path) orelse {
        allocator.free(path);
        return null;
    };
    var d = Dir.openDirAbsolute(io, parent, .{}) catch {
        allocator.free(path);
        return null;
    };
    defer d.close(io);
    // POSIX 下 /tmp 默认 0644 会让同机其他用户读到工具输出：收紧到 0600（Windows 忽略该值）
    const perms: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
    const f = d.createFile(io, std.fs.path.basename(path), .{ .truncate = true, .permissions = perms }) catch {
        allocator.free(path);
        return null;
    };
    defer f.close(io);
    f.writeStreamingAll(io, data) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

/// 删除过期的 bash 截断临时文件（文件名内嵌写入时间戳，无需 stat）。
/// 保留 max_age_ms 内的文件——会话历史里的 stub 仍可能引用它们；
/// 更早的按"临时"语义回收（用户重读旧会话时该路径可能已失效，属预期）。
/// 返回删除数量。由 TUI 启动时调用；失败静默（清理是尽力而为）。
pub fn cleanupStaleBashTempFiles(
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    now_ms: i64,
    max_age_ms: i64,
) usize {
    const dir = bashTempDir(environ_map) orelse return 0;
    var d = Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return 0;
    defer d.close(io);

    var removed: usize = 0;
    var it = d.iterate();
    while (it.next(io) catch return removed) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "skynet-bash-") or !std.mem.endsWith(u8, name, ".txt")) continue;
        const rest = name["skynet-bash-".len .. name.len - ".txt".len];
        const dash = std.mem.indexOfScalar(u8, rest, '-') orelse continue;
        const created = std.fmt.parseInt(i64, rest[0..dash], 10) catch continue;
        if (now_ms - created <= max_age_ms) continue;
        d.deleteFile(io, name) catch continue;
        removed += 1;
    }
    return removed;
}

// ── 目录遍历与通配符 ──

fn shouldSkipDir(name: []const u8) bool {
    const skip = [_][]const u8{
        ".git",  "node_modules", ".zig-cache", "zig-out", "__pycache__",
        ".venv", "venv",         "target",     ".svn",    ".hg",
    };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn joinPath(allocator: Allocator, a: []const u8, b: []const u8) error{OutOfMemory}![]u8 {
    return std.fs.path.join(allocator, &.{ a, b });
}

fn joinRel(allocator: Allocator, prefix: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

/// 递归遍历目录（跳过常见构建/缓存目录；按名字排序保证输出稳定）
fn walk(io: Io, allocator: Allocator, dir_abs: []const u8, rel_prefix: []const u8, depth: u32, ctx: anytype) error{OutOfMemory}!void {
    if (depth > 64) return;
    var dir = Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const Named = struct { name: []u8, kind: Io.File.Kind };
    var entries = std.ArrayListUnmanaged(Named){ .items = &.{}, .capacity = 0 };
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (true) {
        const maybe = it.next(io) catch break;
        const entry = maybe orelse break;
        const name = try allocator.dupe(u8, entry.name);
        try entries.append(allocator, .{ .name = name, .kind = entry.kind });
    }
    std.mem.sort(Named, entries.items, {}, struct {
        fn lessThan(_: void, a: Named, b: Named) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (entries.items) |entry| {
        if (ctx.stop()) return;
        const rel = try joinRel(allocator, rel_prefix, entry.name);
        defer allocator.free(rel);
        switch (entry.kind) {
            .directory => {
                if (shouldSkipDir(entry.name)) continue;
                const abs = try joinPath(allocator, dir_abs, entry.name);
                defer allocator.free(abs);
                try walk(io, allocator, abs, rel, depth + 1, ctx);
            },
            .file => {
                const abs = try joinPath(allocator, dir_abs, entry.name);
                defer allocator.free(abs);
                try ctx.onFile(rel, abs);
            },
            else => {},
        }
    }
}

pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globMatchAt(pattern, 0, path, 0);
}

fn globMatchAt(pat: []const u8, pi_start: usize, p: []const u8, si_start: usize) bool {
    var pi = pi_start;
    var si = si_start;
    while (pi < pat.len) {
        const c = pat[pi];
        if (c == '*') {
            const double = pi + 1 < pat.len and pat[pi + 1] == '*';
            if (double) {
                var next_pi = pi + 2;
                if (next_pi < pat.len and pat[next_pi] == '/') {
                    next_pi += 1;
                    var i = si;
                    while (true) {
                        if (globMatchAt(pat, next_pi, p, i)) return true;
                        const idx = std.mem.indexOfScalarPos(u8, p, i, '/') orelse break;
                        i = idx + 1;
                    }
                    return false;
                }
                var i = si;
                while (i <= p.len) : (i += 1) {
                    if (globMatchAt(pat, next_pi, p, i)) return true;
                }
                return false;
            }
            var i = si;
            while (true) {
                if (globMatchAt(pat, pi + 1, p, i)) return true;
                if (i >= p.len or p[i] == '/') return false;
                i += 1;
            }
        }
        if (si >= p.len) return false;
        switch (c) {
            '?' => {
                if (p[si] == '/') return false;
            },
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, pat, pi + 1, ']') orelse return false;
                if (!classMatch(pat[pi + 1 .. close], p[si])) return false;
                pi = close;
            },
            else => {
                if (c != p[si]) return false;
            },
        }
        pi += 1;
        si += 1;
    }
    return si == p.len;
}

fn classMatch(class: []const u8, c: u8) bool {
    var i: usize = 0;
    var negate = false;
    if (i < class.len and class[i] == '^') {
        negate = true;
        i += 1;
    }
    var hit = false;
    while (i < class.len) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (c >= class[i] and c <= class[i + 2]) hit = true;
            i += 3;
        } else {
            if (c == class[i]) hit = true;
            i += 1;
        }
    }
    return hit != negate;
}

/// 文件名是否匹配 glob（无 '/' 时匹配 basename，有 '/' 时匹配完整相对路径）
fn patternMatchesPath(pattern: []const u8, rel: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        return globMatch(pattern, std.fs.path.basename(rel));
    }
    return globMatch(pattern, rel);
}

fn isBinary(data: []const u8) bool {
    const n = @min(data.len, 4096);
    for (data[0..n]) |c| {
        if (c == 0) return true;
    }
    return false;
}

// ── grep ──

const GrepArgs = struct {
    pattern: []const u8 = "",
    path: []const u8 = "",
    glob: []const u8 = "",
    context: i64 = 0,
    limit: i64 = 0,
    ignore_case: bool = false,
    literal: bool = false,
};

const LineRef = struct { start: usize, end: usize };

fn splitLines(allocator: Allocator, data: []const u8) error{OutOfMemory}![]LineRef {
    var list = std.ArrayListUnmanaged(LineRef){ .items = &.{}, .capacity = 0 };
    errdefer list.deinit(allocator);
    var i: usize = 0;
    // 仅按实际存在的行切分：以 '\n' 结尾的数据不会多出一个空的“幽灵行”，
    // 与 countLines 的行数保持一致（否则 grep 的上下文会多输出一行）。
    while (i < data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, i, '\n');
        const end = nl orelse data.len;
        try list.append(allocator, .{ .start = i, .end = end });
        if (nl == null) break;
        i = end + 1;
    }
    return list.toOwnedSlice(allocator);
}

/// 截断到最多 max 个字符（按码点计；宽字符算 1 个字符）
fn truncateLine(text: []const u8, max: usize) []const u8 {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + n > text.len) break;
        width += 1;
        i += n;
        if (width >= max) return text[0..i];
    }
    return text;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }
    return null;
}

const GrepCtx = struct {
    allocator: Allocator,
    io: Io,
    glob_filter: []const u8,
    re: ?regex.Regex,
    literal: []const u8,
    ignore_case: bool,
    context: usize,
    limit: usize,
    file_label: []const u8,
    single_file: bool,
    out: *std.ArrayListUnmanaged(u8),
    matches: usize = 0,
    truncated: bool = false,
    /// 已达到 limit 且探测到还有更多匹配（用于提示准确性）
    more: bool = false,
    /// 当前输出所属文件（按文件分组：切换文件时打印 `path:` 标题行 + 空行分隔）。
    /// 拥有所有权（复制自 walk 的临时 rel——它每次迭代都会释放）
    last_file: []u8 = &.{},
    /// 已输出的匹配行数（用于顶部 "Found N matches" 统计）
    matched_lines: usize = 0,

    fn stop(self: *@This()) bool {
        return self.truncated or self.more;
    }

    /// 该行是否匹配。正则用 matchesAny 而非 find，以支持锚点等零宽匹配（如 ^ $）。
    fn lineMatches(self: *@This(), text: []const u8) bool {
        if (self.re) |*re| return re.matchesAny(text);
        if (self.ignore_case) return indexOfIgnoreCase(text, self.literal) != null;
        return std.mem.indexOf(u8, text, self.literal) != null;
    }

    fn onFile(self: *@This(), rel: []const u8, abs: []const u8) error{OutOfMemory}!void {
        if (self.stop()) return;
        if (self.glob_filter.len > 0 and !patternMatchesPath(self.glob_filter, rel)) return;

        const data = readFile(self.io, self.allocator, abs, max_grep_file_bytes) catch return;
        defer self.allocator.free(data);
        if (isBinary(data)) return;

        const lines = try splitLines(self.allocator, data);
        defer self.allocator.free(lines);

        // 第一遍：收集匹配的行下标（受剩余配额约束）。多出一条即说明还有更多匹配。
        const budget = self.limit -| self.matches;
        var match_lines = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
        defer match_lines.deinit(self.allocator);
        for (lines, 0..) |line, li| {
            if (self.stop()) return;
            const text = std.mem.trimEnd(u8, data[line.start..line.end], "\r");
            if (!self.lineMatches(text)) continue;
            if (match_lines.items.len >= budget) {
                self.more = true;
                break;
            }
            try match_lines.append(self.allocator, li);
        }
        if (match_lines.items.len == 0) return;

        // 第二遍：合并各匹配点的上下文区间，保证每一行只输出一次；区间覆盖到的
        // 匹配行统一以 ':' 标记，避免同一行既当上下文又当匹配而重复输出。
        const label = if (self.single_file) self.file_label else rel;
        var next_print: usize = 0;
        var mi: usize = 0;
        for (match_lines.items) |li| {
            const ctx_start = li -| self.context;
            const ctx_end = @min(lines.len, li + self.context + 1);
            var j = @max(ctx_start, next_print);
            while (j < ctx_end) : (j += 1) {
                const is_match = mi < match_lines.items.len and match_lines.items[mi] == j;
                if (is_match) {
                    mi += 1;
                    self.matches += 1;
                }
                const text = std.mem.trimEnd(u8, data[lines[j].start..lines[j].end], "\r");
                try self.emit(label, j + 1, text, is_match);
                if (self.out.items.len >= cap_bytes) {
                    self.truncated = true;
                    return;
                }
            }
            next_print = @max(next_print, ctx_end);
        }
    }

    fn emit(self: *@This(), label: []const u8, line_no: usize, text: []const u8, is_match: bool) error{OutOfMemory}!void {
        // 按文件分组（opencode 风格）：文件切换时输出标题行，文件之间空行分隔。
        // 注意 label 来自 walk 的临时切片，需复制后持有（last_file 拥有所有权）。
        if (!std.mem.eql(u8, self.last_file, label)) {
            if (self.last_file.len > 0) try self.out.append(self.allocator, '\n');
            const head = try std.fmt.allocPrint(self.allocator, "{s}:\n", .{label});
            defer self.allocator.free(head);
            try self.out.appendSlice(self.allocator, head);
            if (self.last_file.len > 0) self.allocator.free(self.last_file);
            self.last_file = try self.allocator.dupe(u8, label);
        }
        if (is_match) self.matched_lines += 1;

        const shown = truncateLine(text, max_line_len);
        // 匹配行 `  Line N: text`；上下文行 `  Line N- text`（grep 惯例用 - 区分）
        const sep: u8 = if (is_match) ':' else '-';
        const line = try std.fmt.allocPrint(self.allocator, "  Line {d}{c} {s}\n", .{ line_no, sep, shown });
        defer self.allocator.free(line);
        try self.out.appendSlice(self.allocator, line);
    }
};

fn toolGrep(allocator: Allocator, io: Io, cwd: []const u8, args_json: []const u8) error{OutOfMemory}!Result {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = parseArgs(GrepArgs, args_arena.allocator(), args_json) orelse
        return fail(allocator, "Invalid arguments JSON for grep", .{});
    if (args.pattern.len == 0) return fail(allocator, "Missing required parameter: pattern", .{});

    const search_path = if (args.path.len > 0) args.path else ".";
    const abs = try resolvePath(allocator, cwd, search_path);
    defer allocator.free(abs);

    var re: ?regex.Regex = null;
    if (!args.literal) {
        re = regex.Regex.compile(allocator, args.pattern, .{ .ignore_case = args.ignore_case }) catch {
            return fail(allocator, "Invalid regular expression: {s}", .{args.pattern});
        };
    }
    defer if (re) |*r| r.deinit();

    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    const single_file = !isDir(io, abs);
    if (single_file) {
        if (!fileExists(io, abs)) {
            out.deinit(allocator);
            return fail(allocator, "Path not found: {s}", .{search_path});
        }
    }

    var ctx = GrepCtx{
        .allocator = allocator,
        .io = io,
        .glob_filter = args.glob,
        .re = re,
        .literal = args.pattern,
        .ignore_case = args.ignore_case,
        .context = if (args.context > 0) @intCast(@min(args.context, 50)) else 0,
        .limit = if (args.limit > 0) @intCast(args.limit) else 100,
        .file_label = if (single_file) search_path else "",
        .single_file = single_file,
        .out = &out,
    };

    if (single_file) {
        try ctx.onFile(search_path, abs);
    } else {
        try walk(io, allocator, abs, "", 0, &ctx);
    }
    defer if (ctx.last_file.len > 0) allocator.free(ctx.last_file);

    if (out.items.len == 0) {
        out.deinit(allocator);
        return ok(allocator, "No matches found", .{});
    }

    // 顶部统计（opencode 风格）：`Found N matches`，后接空行
    {
        const header = try std.fmt.allocPrint(allocator, "Found {d} match{s}\n\n", .{
            ctx.matched_lines,
            if (ctx.matched_lines == 1) "" else "es",
        });
        defer allocator.free(header);
        try out.insertSlice(allocator, 0, header);
    }

    if (ctx.truncated) {
        const notice = try std.fmt.allocPrint(allocator, "\n[Output truncated at 50.0KB. Refine the pattern or search a narrower path to see the rest.]", .{});
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    } else if (ctx.more) {
        const limit = ctx.limit;
        const notice = try std.fmt.allocPrint(allocator, "\n[{d} matches limit reached. Use limit={d} for more, or refine the pattern.]", .{ limit, limit * 2 });
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    }
    return .{ .content = try out.toOwnedSlice(allocator), .is_error = false };
}

// ── find ──

const FindArgs = struct {
    pattern: []const u8 = "",
    path: []const u8 = "",
    limit: i64 = 0,
};

const FindCtx = struct {
    allocator: Allocator,
    pattern: []const u8,
    limit: usize,
    out: *std.ArrayListUnmanaged([]u8),
    count: usize = 0,

    fn stop(self: *@This()) bool {
        return self.count >= self.limit;
    }

    fn onFile(self: *@This(), rel: []const u8, abs: []const u8) error{OutOfMemory}!void {
        _ = abs;
        if (!patternMatchesPath(self.pattern, rel)) return;
        const copy = try self.allocator.dupe(u8, rel);
        errdefer self.allocator.free(copy);
        try self.out.append(self.allocator, copy);
        self.count += 1;
    }
};

fn toolFind(allocator: Allocator, io: Io, cwd: []const u8, args_json: []const u8) error{OutOfMemory}!Result {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = parseArgs(FindArgs, args_arena.allocator(), args_json) orelse
        return fail(allocator, "Invalid arguments JSON for find", .{});
    if (args.pattern.len == 0) return fail(allocator, "Missing required parameter: pattern", .{});

    const search_path = if (args.path.len > 0) args.path else ".";
    const abs = try resolvePath(allocator, cwd, search_path);
    defer allocator.free(abs);
    if (!isDir(io, abs)) {
        return fail(allocator, "Path is not a directory: {s}", .{search_path});
    }

    const limit: usize = if (args.limit > 0) @intCast(args.limit) else 1000;
    var hits = std.ArrayListUnmanaged([]u8){ .items = &.{}, .capacity = 0 };
    defer {
        for (hits.items) |h| allocator.free(h);
        hits.deinit(allocator);
    }

    // 多收集 1 条用于准确判断"是否还有更多结果"
    var ctx = FindCtx{ .allocator = allocator, .pattern = args.pattern, .limit = limit + 1, .out = &hits };
    try walk(io, allocator, abs, "", 0, &ctx);

    if (hits.items.len == 0) {
        return ok(allocator, "No files found matching pattern", .{});
    }

    const has_more = hits.items.len > limit;
    const shown = @min(hits.items.len, limit);

    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var written: usize = 0;
    var byte_capped = false;
    for (hits.items[0..shown]) |h| {
        if (out.items.len + h.len + 1 > cap_bytes) {
            byte_capped = true;
            break;
        }
        try out.appendSlice(allocator, h);
        try out.append(allocator, '\n');
        written += 1;
    }
    if (byte_capped) {
        const notice = try std.fmt.allocPrint(allocator, "\n[Output truncated at 50.0KB: showing {d} of {d} results. Refine the pattern or search a narrower path.]", .{ written, hits.items.len });
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    } else if (has_more) {
        const notice = try std.fmt.allocPrint(allocator, "\n[{d} results limit reached. Use limit={d} for more, or refine the pattern.]", .{ limit, limit * 2 });
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    }
    return .{ .content = try out.toOwnedSlice(allocator), .is_error = false };
}

// ── ls ──

const LsArgs = struct {
    path: []const u8 = "",
    limit: i64 = 0,
    /// 递归深度：0 = 只列当前层（默认，保持原行为）；N > 0 = 递归 N 层。
    depth: i64 = 0,
};

/// ls 递归：自包含的深度受限遍历（不依赖 walk，输出"相对路径（目录带 /）"）。
/// 复用 shouldSkipDir 跳过 .git 等目录。
fn lsRecurse(
    io: Io,
    allocator: Allocator,
    dir_abs: []const u8,
    rel_prefix: []const u8,
    remaining: u32,
    out: *std.ArrayListUnmanaged([]u8),
) error{OutOfMemory}!void {
    if (remaining == 0) return;
    var dir = Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const Named = struct { name: []u8, is_dir: bool };
    var entries = std.ArrayListUnmanaged(Named){ .items = &.{}, .capacity = 0 };
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }
    var it = dir.iterate();
    while (true) {
        const maybe = it.next(io) catch break;
        const entry = maybe orelse break;
        if (shouldSkipDir(entry.name)) continue;
        const name = try allocator.dupe(u8, entry.name);
        try entries.append(allocator, .{ .name = name, .is_dir = entry.kind == .directory });
    }
    std.mem.sort(Named, entries.items, {}, struct {
        fn lessThan(_: void, a: Named, b: Named) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    for (entries.items) |e| {
        const rel = if (rel_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, e.name })
        else
            try allocator.dupe(u8, e.name);
        if (e.is_dir) {
            defer allocator.free(rel);
            const line = try std.fmt.allocPrint(allocator, "{s}/", .{rel});
            errdefer allocator.free(line);
            try out.append(allocator, line);
            const child_abs = try joinPath(allocator, dir_abs, e.name);
            defer allocator.free(child_abs);
            try lsRecurse(io, allocator, child_abs, rel, remaining - 1, out);
        } else {
            errdefer allocator.free(rel);
            try out.append(allocator, rel);
        }
    }
}

fn toolLs(allocator: Allocator, io: Io, cwd: []const u8, args_json: []const u8) error{OutOfMemory}!Result {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = parseArgs(LsArgs, args_arena.allocator(), args_json) orelse
        return fail(allocator, "Invalid arguments JSON for ls", .{});

    const list_path = if (args.path.len > 0) args.path else ".";
    const abs = try resolvePath(allocator, cwd, list_path);
    defer allocator.free(abs);

    if (!isDir(io, abs)) {
        if (fileExists(io, abs)) {
            return fail(allocator, "Not a directory: {s}", .{list_path});
        } else {
            return fail(allocator, "Path not found: {s}", .{list_path});
        }
    }

    // depth > 0：递归列出（相对路径，目录带 '/' 后缀）
    if (args.depth > 0) {
        const depth: u32 = @intCast(@min(args.depth, 32));
        var paths = std.ArrayListUnmanaged([]u8){ .items = &.{}, .capacity = 0 };
        defer {
            for (paths.items) |p| allocator.free(p);
            paths.deinit(allocator);
        }
        try lsRecurse(io, allocator, abs, "", depth, &paths);
        if (paths.items.len == 0) return ok(allocator, "(empty directory)", .{});

        const limit: usize = if (args.limit > 0) @intCast(args.limit) else 500;
        var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
        errdefer out.deinit(allocator);
        var shown: usize = 0;
        var byte_capped = false;
        for (paths.items) |p| {
            if (shown >= limit) break;
            if (out.items.len + p.len + 1 > cap_bytes) {
                byte_capped = true;
                break;
            }
            try out.appendSlice(allocator, p);
            try out.append(allocator, '\n');
            shown += 1;
        }
        if (byte_capped or paths.items.len > limit) {
            const notice = try std.fmt.allocPrint(allocator, "\n[Showing {d} of {d} entries. Use a narrower path or increase limit.]", .{ shown, paths.items.len });
            defer allocator.free(notice);
            try out.appendSlice(allocator, notice);
        }
        return .{ .content = try out.toOwnedSlice(allocator), .is_error = false };
    }

    var dir = Dir.openDirAbsolute(io, abs, .{ .iterate = true }) catch {
        return fail(allocator, "Cannot read directory: {s}", .{list_path});
    };
    defer dir.close(io);

    const Named = struct { name: []u8, is_dir: bool };
    var entries = std.ArrayListUnmanaged(Named){ .items = &.{}, .capacity = 0 };
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (true) {
        const maybe = it.next(io) catch break;
        const entry = maybe orelse break;
        const name = try allocator.dupe(u8, entry.name);
        try entries.append(allocator, .{ .name = name, .is_dir = entry.kind == .directory });
    }

    std.mem.sort(Named, entries.items, {}, struct {
        fn lessThan(_: void, a: Named, b: Named) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    if (entries.items.len == 0) {
        return ok(allocator, "(empty directory)", .{});
    }

    const limit: usize = if (args.limit > 0) @intCast(args.limit) else 500;
    var out = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var shown: usize = 0;
    var byte_capped = false;
    for (entries.items) |e| {
        if (shown >= limit) break;
        const line_len = e.name.len + 1 + @as(usize, if (e.is_dir) 1 else 0);
        if (out.items.len + line_len > cap_bytes) {
            byte_capped = true;
            break;
        }
        try out.appendSlice(allocator, e.name);
        if (e.is_dir) try out.append(allocator, '/');
        try out.append(allocator, '\n');
        shown += 1;
    }
    if (byte_capped) {
        const notice = try std.fmt.allocPrint(allocator, "\n[Output truncated at 50.0KB: showing {d} of {d} entries.]", .{ shown, entries.items.len });
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    } else if (shown >= limit and entries.items.len > shown) {
        const notice = try std.fmt.allocPrint(allocator, "\n[{d} entries limit reached. Use limit={d} for more.]", .{ limit, limit * 2 });
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    }
    return .{ .content = try out.toOwnedSlice(allocator), .is_error = false };
}

// ── 测试 ──

const testing = std.testing;

fn testIo(threaded: *std.Io.Threaded) Io {
    threaded.* = .init(testing.allocator, .{});
    return threaded.io();
}

fn removeTree(io: Io, allocator: Allocator, abs: []const u8) void {
    var dir = Dir.openDirAbsolute(io, abs, .{ .iterate = true }) catch return;
    var it = dir.iterate();
    while (true) {
        const maybe = it.next(io) catch break;
        const entry = maybe orelse break;
        const child = std.fs.path.join(allocator, &.{ abs, entry.name }) catch return;
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => removeTree(io, allocator, child),
            else => Dir.deleteFileAbsolute(io, child) catch {},
        }
    }
    dir.close(io);
    Dir.deleteDirAbsolute(io, abs) catch {};
}

test "tools: glob 匹配" {
    try testing.expect(globMatch("*.zig", "main.zig"));
    try testing.expect(!globMatch("*.zig", "main.zon"));
    try testing.expect(globMatch("**/*.zig", "src/a/b/main.zig"));
    try testing.expect(globMatch("src/**/*.zig", "src/a/b/main.zig"));
    try testing.expect(globMatch("src/**/*.zig", "src/main.zig"));
    try testing.expect(!globMatch("src/**/*.zig", "lib/main.zig"));
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "a/c"));
    try testing.expect(globMatch("[ab]x", "ax"));
    try testing.expect(globMatch("*.{zig}", "x.{zig}"));
}

test "tools: read/write/edit/ls/find/grep 基础流程" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_tools";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    // write：自动建目录
    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_tools/src/a.txt\",\"content\":\"hello\\nworld\\nfoo bar\\n\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "Successfully wrote") != null);
    }

    // write：目标是已存在的目录 → 明确报错（而不是模糊的 IO 错误）
    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_tools/src\",\"content\":\"x\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "directory, not a file") != null);
    }

    // read：offset/limit（附续读提示；行号前缀为绝对行号）
    {
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_tools/src/a.txt\",\"offset\":2,\"limit\":1}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("2: world\n\n[Showing lines 2-2 of 3. Use offset=3 to continue.]", r.content);
    }

    // read：文件不存在 / 目录
    {
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_tools/nope.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "File not found") != null);
    }

    // edit：精确替换
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_tools/src/a.txt\",\"edits\":[{\"old_text\":\"world\",\"new_text\":\"Zig\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        const rd = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_tools/src/a.txt\"}");
        defer testing.allocator.free(rd.content);
        try testing.expect(std.mem.indexOf(u8, rd.content, "Zig") != null);
    }

    // edit：不唯一（edits[] 形式）
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_tools/src/a.txt\",\"edits\":[{\"old_text\":\"o\",\"new_text\":\"0\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "occurrences") != null);
    }

    // edit：单条成功（edits[] 一个元素）
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_tools/src/a.txt\",\"edits\":[{\"old_text\":\"foo bar\",\"new_text\":\"foo BAR\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "1 edit in") != null);
    }

    // edit：找不到
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_tools/src/a.txt\",\"edits\":[{\"old_text\":\"不存在的内容\",\"new_text\":\"x\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "could not find") != null);
    }

    // ls：目录后缀与排序
    {
        const r = try execute(testing.allocator, io, cwd, "ls", "{\"path\":\"skynet_test_tools\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("src/\n", r.content);
    }

    // find：glob
    {
        const r = try execute(testing.allocator, io, cwd, "find", "{\"pattern\":\"*.txt\",\"path\":\"skynet_test_tools\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("src/a.txt\n", r.content);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "find", "{\"pattern\":\"**/*.zig\",\"path\":\"skynet_test_tools\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "No files found") != null);
    }

    // 为 grep 的忽略大小写测试准备独立文件
    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_tools/src/b.txt\",\"content\":\"Hello World\\nsecond line\\n\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }

    // find：结果数恰好等于 limit 时不应误报"limit reached"
    {
        const r = try execute(testing.allocator, io, cwd, "find", "{\"pattern\":\"*.txt\",\"path\":\"skynet_test_tools\",\"limit\":2}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("src/a.txt\nsrc/b.txt\n", r.content);
    }
    // find：超过 limit 时正常提示并截断
    {
        const r = try execute(testing.allocator, io, cwd, "find", "{\"pattern\":\"*.txt\",\"path\":\"skynet_test_tools\",\"limit\":1}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "limit reached") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "src/b.txt") == null);
    }

    // grep：正则与字面量
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"w[0-9]rld|Zig\",\"path\":\"skynet_test_tools\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "src/a.txt:") != null);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"hello\",\"path\":\"skynet_test_tools/src/b.txt\",\"literal\":true,\"ignore_case\":true}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "Hello World") != null);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"hello\",\"path\":\"skynet_test_tools/src/b.txt\",\"literal\":true}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("No matches found", r.content);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"zzz_no_match\",\"path\":\"skynet_test_tools\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("No matches found", r.content);
    }

    // grep：context 行
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"Zig\",\"path\":\"skynet_test_tools\",\"context\":1}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "  Line 1- hello") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "  Line 2: Zig") != null);
    }

    // grep：结果数恰好等于 limit 时不应误报
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"Hello\",\"path\":\"skynet_test_tools/src/b.txt\",\"limit\":1}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "Hello World") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "limit reached") == null);
    }
    // grep：超过 limit 时提示并截断
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"e\",\"path\":\"skynet_test_tools/src/b.txt\",\"literal\":true,\"limit\":1}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "limit reached") != null);
    }
}

test "tools: edit 生成行号 diff 展示" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_diff";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_diff/a.txt\",\"content\":\"l1\\nl2\\nl3\\nl4\\nl5\\nl6\\nl7\\nl8\\nl9\\nl10\\n\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }
    {
        // 把 l5 换成两行（L5 / L5b）：删除 1 行、新增 2 行
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_diff/a.txt\",\"edits\":[{\"old_text\":\"l5\",\"new_text\":\"L5\\nL5b\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);

        const expected =
            "     …\n" ++
            "    2   l2\n" ++
            "    3   l3\n" ++
            "    4   l4\n" ++
            "    5 - l5\n" ++
            "    5 + L5\n" ++
            "    6 + L5b\n" ++
            "    7   l6\n" ++
            "    8   l7\n" ++
            "    9   l8\n" ++
            "     …";
        try testing.expectEqualStrings(expected, r.display.?);
    }
}

test "tools: edit 宽松匹配（放宽链）与失败诊断" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_edit_diag";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_edit_diag/a.txt\",\"content\":\"alpha\\nbeta   \\ngamma\\n\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }

    // ── 放宽链：这些以前全部失败，现在应自动匹配成功并带短标记 ──

    {
        // 行尾空白差异（级别 1 trailing-whitespace）：文件 "beta   "，old "beta"
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/a.txt\",\"edits\":[{\"old_text\":\"beta\\ngamma\",\"new_text\":\"B\\nG\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "trailing-whitespace") != null);
    }
    {
        // 行首缩进差异（级别 4 indentation-flexible）：独立文件，文件行 "gamma"，old 行 "  gamma"
        {
            const w = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_edit_diag/e.txt\",\"content\":\"alpha\\ngamma\\n\"}");
            defer testing.allocator.free(w.content);
            defer if (w.display) |d| testing.allocator.free(d);
            try testing.expect(!w.is_error);
        }
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/e.txt\",\"edits\":[{\"old_text\":\"  gamma\",\"new_text\":\"GAMMA\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "indentation-flexible") != null);
    }
    {
        // 转义层数差异（级别 3 escape-normalized）：文件 2 个反斜杠，old 写 1 个
        {
            const w = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_edit_diag/b.txt\",\"content\":\"row1\\\\\\\\row2\"}");
            defer testing.allocator.free(w.content);
            defer if (w.display) |d| testing.allocator.free(d);
            try testing.expect(!w.is_error);
        }
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/b.txt\",\"edits\":[{\"old_text\":\"row1\\\\row2\",\"new_text\":\"row1\\\\ROW2\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "escape-normalized") != null);
    }
    {
        // 内部多空格（级别 2 whitespace-insensitive）：文件 "a  b"，old "a b"
        {
            const w = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_edit_diag/c.txt\",\"content\":\"x  y\"}");
            defer testing.allocator.free(w.content);
            defer if (w.display) |d| testing.allocator.free(d);
        }
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/c.txt\",\"edits\":[{\"old_text\":\"x y\",\"new_text\":\"X Y\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "whitespace-insensitive") != null);
    }

    {
        // 同一调用里两条编辑都走同一放宽级别 → 标记合并为 "namex2"（不重复占 token）
        {
            const w = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_edit_diag/g.txt\",\"content\":\"p  q\\nr  s\\n\"}");
            defer testing.allocator.free(w.content);
            defer if (w.display) |d| testing.allocator.free(d);
            try testing.expect(!w.is_error);
        }
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/g.txt\",\"edits\":[{\"old_text\":\"p q\",\"new_text\":\"P Q\"},{\"old_text\":\"r s\",\"new_text\":\"R S\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "whitespace-insensitivex2") != null);
    }

    // ── lineAnchored 纯函数单测（放宽匹配的行对齐保护） ──
    {
        const d1 = "    keep   indented();\n";
        // 命中 "indented();"（起点前有 "keep   " 非空白）→ 拒绝
        const s0 = std.mem.indexOf(u8, d1, "indented();").?;
        try testing.expect(!lineAnchored(d1, s0, s0 + "indented();".len));
        // 命中整行（两侧到边界只有空白）→ 通过
        try testing.expect(lineAnchored(d1, 0, d1.len - 1));
        // 命中行首缩进后的内容（起点前只有空白）→ 通过（"child();" 是 8 字符：8..16）
        try testing.expect(lineAnchored("        child();\n", 8, 16));
        // 行尾残留非空白 → 拒绝
        try testing.expect(!lineAnchored("abc TABLE x (", 0, 3));
        // 行中间到行尾（终点后无内容）→ 起点前非空白 → 拒绝
        try testing.expect(!lineAnchored("keep   indented();", 7, 18));
    }

    // ── 边界保护：标识符被切开 → 拒绝（不静默改坏） ──
    {
        {
            const w = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_edit_diag/d.txt\",\"content\":\"value INTEGER\"}");
            defer testing.allocator.free(w.content);
            defer if (w.display) |d| testing.allocator.free(d);
        }
        // old "value INT"（子串命中，尾部残留 "EGER" 会与新文本粘连）
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/d.txt\",\"edits\":[{\"old_text\":\"value INT\",\"new_text\":\"value BIG\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "splits an identifier") != null);
    }

    // ── 真失败：所有级别都不适用时，仍给逐行诊断 ──
    {
        // 首行存在（alpha）但后续行差异大且无法靠放宽链对齐 → 诊断（独立文件）
        {
            const w = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_edit_diag/f.txt\",\"content\":\"alpha\\nbeta\\ngamma\\n\"}");
            defer testing.allocator.free(w.content);
            defer if (w.display) |d| testing.allocator.free(d);
        }
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/f.txt\",\"edits\":[{\"old_text\":\"alpha\\nZZZ_NOT_THERE\\nQQQ\",\"new_text\":\"x\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "does not match") != null);
    }
    {
        // 完全无关：无 Hint，不崩
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_diag/f.txt\",\"edits\":[{\"old_text\":\"ZZZ_NOT_IN_FILE_AT_ALL\",\"new_text\":\"x\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "Hint:") == null);
    }
}

test "tools: edit edits[]——成功 / 重叠 / 不唯一 / 不匹配（全有或全无）/ 容错解析" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_edit_multi";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    const write = struct {
        fn call(a: std.mem.Allocator, io_: Io, cwd_: []const u8, body: []const u8) !void {
            const r = try execute(a, io_, cwd_, "write", body);
            defer a.free(r.content);
            defer if (r.display) |d| a.free(d);
            try testing.expect(!r.is_error);
        }
    }.call;

    const read = struct {
        fn call(a: std.mem.Allocator, io_: Io, cwd_: []const u8) ![]u8 {
            const r = try execute(a, io_, cwd_, "read", "{\"path\":\"skynet_test_edit_multi/f.txt\"}");
            defer if (r.display) |d| a.free(d);
            defer a.free(r.content);
            return a.dupe(u8, r.content);
        }
    }.call;

    // 成功：两处不相交替换，一次调用完成
    {
        try write(testing.allocator, io, cwd, "{\"path\":\"skynet_test_edit_multi/f.txt\",\"content\":\"alpha\\nbeta\\ngamma\\ndelta\\n\"}");
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_multi/f.txt\",\"edits\":[{\"old_text\":\"alpha\",\"new_text\":\"ALPHA\"},{\"old_text\":\"gamma\",\"new_text\":\"GAMMA\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "2 edits in") != null);
        const content = try read(testing.allocator, io, cwd);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "ALPHA") != null);
        try testing.expect(std.mem.indexOf(u8, content, "GAMMA") != null);
        try testing.expect(std.mem.indexOf(u8, content, "beta") != null); // 未动的保留
    }

    // 重叠：报错并指出是哪两条（不写文件）
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_multi/f.txt\",\"edits\":[{\"old_text\":\"ALPHA\\nbeta\",\"new_text\":\"X\"},{\"old_text\":\"beta\\nGAMMA\",\"new_text\":\"Y\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "overlap") != null);
        const content = try read(testing.allocator, io, cwd);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "ALPHA") != null); // 未被改动
    }

    // 不唯一：报错并给出出现次数
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_multi/f.txt\",\"edits\":[{\"old_text\":\"a\",\"new_text\":\"A\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "edits[0]") != null);
    }

    // 不匹配：报错（全有或全无——第一处成功、第二处失败 → 不写文件）
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_multi/f.txt\",\"edits\":[{\"old_text\":\"delta\",\"new_text\":\"DELTA\"},{\"old_text\":\"NOT_PRESENT\",\"new_text\":\"X\"}]}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "edits[1]") != null);
        const content = try read(testing.allocator, io, cwd);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "DELTA") == null); // 第一处也未应用
    }

    // 容错：edits 传成单个对象（而非数组）也能解析
    {
        const r = try execute(testing.allocator, io, cwd, "edit", "{\"path\":\"skynet_test_edit_multi/f.txt\",\"edits\":{\"old_text\":\"delta\",\"new_text\":\"DELTA\"}}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        const content = try read(testing.allocator, io, cwd);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "DELTA") != null);
    }
}

test "tools: ls 递归（depth 参数、目录后缀、跳过规则、limit 提示）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_ls_depth";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    // 构造：a.txt / sub/b.txt / sub/deep/c.txt / .git/ignored
    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_ls_depth/a.txt\",\"content\":\"a\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_ls_depth/sub/b.txt\",\"content\":\"b\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_ls_depth/sub/deep/c.txt\",\"content\":\"c\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_ls_depth/.git/ignored\",\"content\":\"x\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }

    {
        // depth=1：只列一层
        const r = try execute(testing.allocator, io, cwd, "ls", "{\"path\":\"skynet_test_ls_depth\",\"depth\":1}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "a.txt") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "sub/") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "sub/b.txt") == null); // 未下钻
        try testing.expect(std.mem.indexOf(u8, r.content, ".git") == null); // 跳过
    }
    {
        // depth=2：下钻一层（相对路径、目录带 /）
        const r = try execute(testing.allocator, io, cwd, "ls", "{\"path\":\"skynet_test_ls_depth\",\"depth\":2}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "sub/b.txt") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "sub/deep/") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "sub/deep/c.txt") == null); // 第三层不下钻
    }
    {
        // depth=0（默认）：只列当前层，与原行为一致
        const r = try execute(testing.allocator, io, cwd, "ls", "{\"path\":\"skynet_test_ls_depth\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "a.txt") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "sub") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "b.txt") == null); // 不递归
    }
}

test "tools: 大改动 diff 同时显示删除与新增行" {
    // 全部 60 行都发生改变，超过 diff_max_lines(40)：必须 `-` 与 `+` 都出现，
    // 不能只显示删除行（否则看起来像把内容删掉了）。
    var old_buf: [8192]u8 = undefined;
    var new_buf: [8192]u8 = undefined;
    var old_len: usize = 0;
    var new_len: usize = 0;
    var n: usize = 0;
    while (n < 60) : (n += 1) {
        old_len += (try std.fmt.bufPrint(old_buf[old_len..], "line {d} AAAA\n", .{n + 1})).len;
        new_len += (try std.fmt.bufPrint(new_buf[new_len..], "line {d} BBBB\n", .{n + 1})).len;
    }
    const diff = try buildEditDiff(testing.allocator, old_buf[0..old_len], new_buf[0..new_len]);
    defer testing.allocator.free(diff);

    try testing.expect(std.mem.indexOf(u8, diff, " - ") != null);
    try testing.expect(std.mem.indexOf(u8, diff, " + ") != null);
    try testing.expect(std.mem.indexOf(u8, diff, "     …") != null);
}

test "tools: bash 输出去除 ANSI 转义序列" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // PowerShell 风格颜色码
        .{ .in = "\x1b[31;1m红色\x1b[0m normal", .want = "红色 normal" },
        // CSI 带私人参数 + 清行
        .{ .in = "a\x1b[?25lb\x1b[Kc", .want = "abc" },
        // OSC 标题（BEL 终止）
        .{ .in = "\x1b]0;title\x07text", .want = "text" },
        // OSC 标题（ST 终止）
        .{ .in = "\x1b]8;;http://x\x1b\\link", .want = "link" },
        // 无转义原样返回
        .{ .in = "plain text 中文", .want = "plain text 中文" },
        // 未终止的 CSI：丢弃到结尾
        .{ .in = "tail\x1b[38;5;", .want = "tail" },
    };
    for (cases) |case| {
        const out = try stripAnsiAlloc(testing.allocator, case.in);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(case.want, out);
    }
}

test "tools: bash 输出与错误码" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    {
        const r = try execute(testing.allocator, io, cwd, "bash", "{\"command\":\"Write-Output hi\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expectEqualStrings("hi\n", r.content);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "bash", "{\"command\":\"exit 3\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "exited with code 3") != null);
    }
    // 中文 Windows 控制台代码页不是 UTF-8：pwsh 输出必须仍是 UTF-8
    {
        const r = try execute(testing.allocator, io, cwd, "bash", "{\"command\":\"Write-Output 测试中文\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expectEqualStrings("测试中文\n", r.content);
    }
    {
        const r = try execute(testing.allocator, io, cwd, "bash", "{\"command\":\"Write-Error 错误信息\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "错误信息") != null);
    }
}

test "tools: 行截断按字符数上限（不多截一个）" {
    var long: [600]u8 = @splat('a');
    try testing.expectEqual(@as(usize, 500), truncateLine(&long, 500).len);
    try testing.expectEqual(@as(usize, 600), truncateLine(&long, 600).len);
    try testing.expectEqual(@as(usize, 5), truncateLine("short", 500).len);
    try testing.expectEqualStrings("中文", truncateLine("中文abc", 2));
}

test "tools: capTail 保留前导空行且不误报截断" {
    // 输出以空行开头时，整段内容必须原样保留、且不得出现截断提示
    const cases = [_][]const u8{
        "\nx\ny\n",
        "\n\nx\ny\n",
        "\n",
        "\n\n",
        "\n\ny",
        "x\ny\n",
    };
    for (cases) |data| {
        const cap = try capTail(testing.allocator, data, 2000, 50 * 1024);
        defer testing.allocator.free(cap.text);
        defer if (cap.notice.len > 0) testing.allocator.free(cap.notice);
        try testing.expectEqualStrings(data, cap.text);
        try testing.expectEqual(@as(usize, 0), cap.notice.len);
    }

    // 真正的尾部截断仍应正确：保留最后 N 行并给出准确的起始行号
    {
        const cap = try capTail(testing.allocator, "a\nb\nc\nd\n", 2, 50 * 1024);
        defer testing.allocator.free(cap.text);
        defer testing.allocator.free(cap.notice);
        try testing.expectEqualStrings("c\nd\n", cap.text);
        try testing.expectEqualStrings("[Showing lines 3-4 of 4.]", cap.notice);
    }

    // 单行超字节上限的退化分支：起始行号应为其所在行（最后一行），而非 total+1
    {
        var huge: [8 * 1024]u8 = @splat('x');
        huge[0] = '\n'; // 前置空行也存在，确认不会把它算成额外行
        const cap = try capTail(testing.allocator, &huge, 2000, 1024);
        defer testing.allocator.free(cap.text);
        defer testing.allocator.free(cap.notice);
        try testing.expectEqualStrings("[Showing lines 2-2 of 2.]", cap.notice);
    }
}

test "tools: bash 截断时全文落临时文件（可用 read 续看，无需重跑）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    // 自建临时目录作为 TEMP，避免污染系统目录
    const tmp_dir = try std.fs.path.join(testing.allocator, &.{ cwd, "skynet_test_bash_tmp" });
    defer testing.allocator.free(tmp_dir);
    removeTree(io, testing.allocator, tmp_dir);
    defer removeTree(io, testing.allocator, tmp_dir);
    makeDirs(io, tmp_dir);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("TEMP", tmp_dir);

    // 输出 100KB（超过 50KB 上限）→ 截断且给出全文路径
    const r = try executeWithEnv(
        testing.allocator,
        io,
        cwd,
        "bash",
        "{\"command\":\"Write-Output ('x' * 100000)\"}",
        &env,
    );
    defer testing.allocator.free(r.content);
    defer if (r.display) |d| testing.allocator.free(d);
    try testing.expect(!r.is_error);
    const marker = "Full output saved to: ";
    const pos = std.mem.indexOf(u8, r.content, marker) orelse {
        // 非 Windows 环境（无 pwsh）时跳过：本测试依赖 pwsh 语法
        return error.SkipZigTest;
    };
    const path = std.mem.trimEnd(u8, r.content[pos + marker.len ..], " \r\n");
    try testing.expect(std.mem.indexOf(u8, path, "skynet-bash-") != null);

    // 临时文件应保存全文（100000 个 x + 换行），远大于截断后的可见部分
    const full = try readFile(io, testing.allocator, path, 1024 * 1024);
    defer testing.allocator.free(full);
    try testing.expect(full.len >= 100_000);
    try testing.expect(std.mem.indexOf(u8, full, "xxxx") != null);
    try testing.expect(std.mem.indexOf(u8, r.content, "[Showing lines") != null);

    // 无 TEMP/TMPDIR 环境变量时优雅降级：不写文件、提示保留
    {
        var empty_env = std.process.Environ.Map.init(testing.allocator);
        defer empty_env.deinit();
        const r2 = try executeWithEnv(
            testing.allocator,
            io,
            cwd,
            "bash",
            "{\"command\":\"Write-Output ('y' * 100000)\"}",
            &empty_env,
        );
        defer testing.allocator.free(r2.content);
        defer if (r2.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r2.content, "[Showing lines") != null);
        try testing.expect(std.mem.indexOf(u8, r2.content, marker) == null);
    }
}

test "tools: 过期 bash 临时文件启动清理" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const tmp_dir = try std.fs.path.join(testing.allocator, &.{ cwd, "skynet_test_bash_cleanup" });
    defer testing.allocator.free(tmp_dir);
    removeTree(io, testing.allocator, tmp_dir);
    defer removeTree(io, testing.allocator, tmp_dir);
    makeDirs(io, tmp_dir);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("TEMP", tmp_dir);

    const now_ms: i64 = 1_000_000_000_000;
    const age: i64 = 7 * 24 * 60 * 60 * 1000; // 7 天
    const old_ts = now_ms - age - 1000; // 过期
    const new_ts = now_ms - 60_000; // 未过期

    var buf_old: [64]u8 = undefined;
    const name_old = try std.fmt.bufPrint(&buf_old, "skynet-bash-{d}-1.txt", .{old_ts});
    var buf_new: [64]u8 = undefined;
    const name_new = try std.fmt.bufPrint(&buf_new, "skynet-bash-{d}-2.txt", .{new_ts});
    const kept_names = [_][]const u8{
        name_new,
        "skynet-bash-abc-3.txt", // 时间戳不可解析 → 留
        "other-999999000000-4.txt", // 前缀不符 → 留
        "skynet-bash-999999000000-5.log", // 扩展名不符 → 留
    };
    {
        var d = try Dir.openDirAbsolute(io, tmp_dir, .{});
        defer d.close(io);
        var f = try d.createFile(io, name_old, .{});
        f.close(io);
        for (kept_names) |n| {
            var k = try d.createFile(io, n, .{});
            k.close(io);
        }
    }

    const removed = cleanupStaleBashTempFiles(io, &env, now_ms, age);
    try testing.expectEqual(@as(usize, 1), removed);

    var d = try Dir.openDirAbsolute(io, tmp_dir, .{ .iterate = true });
    defer d.close(io);
    var old_gone = true;
    var kept_count: usize = 0;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, name_old)) old_gone = false;
        kept_count += 1;
    }
    try testing.expect(old_gone);
    try testing.expectEqual(kept_names.len, kept_count);

    // 无 TEMP/TMPDIR → 不做任何事
    var empty_env = std.process.Environ.Map.init(testing.allocator);
    defer empty_env.deinit();
    try testing.expectEqual(@as(usize, 0), cleanupStaleBashTempFiles(io, &empty_env, now_ms, 0));
}

test "tools: grep 重叠上下文不重复输出，且不以换行结尾时不多出幽灵行" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_grep_ctx";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_grep_ctx/a.txt\",\"content\":\"L1\\nmatchA\\nL3\\nmatchB\\nL5\\n\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }

    // 两个匹配点的上下文区间重叠：每行只能出现一次；匹配行统一用 ':' 标记；
    // 文件以 '\n' 结尾，不应多出一行空上下文（行号 6）。
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"match[AB]\",\"path\":\"skynet_test_grep_ctx\",\"context\":2}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        const expected =
            "Found 2 matches\n" ++
            "\n" ++
            "a.txt:\n" ++
            "  Line 1- L1\n" ++
            "  Line 2: matchA\n" ++
            "  Line 3- L3\n" ++
            "  Line 4: matchB\n" ++
            "  Line 5- L5\n";
        try testing.expectEqualStrings(expected, r.content);
    }

    // context=0 时同样只输出匹配行。
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"match[AB]\",\"path\":\"skynet_test_grep_ctx/a.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings(
            "Found 2 matches\n" ++
                "\n" ++
                "skynet_test_grep_ctx/a.txt:\n" ++
                "  Line 2: matchA\n" ++
                "  Line 4: matchB\n",
            r.content,
        );
    }
}

test "tools: read 单行超字节上限时提示不再指向越界的 offset" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_oneline_big";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    // 单行 90KB（无换行），超过 50KB 字节上限；整份文件只有这一行。
    const content = try testing.allocator.alloc(u8, 90 * 1024);
    defer testing.allocator.free(content);
    @memset(content, 'x');

    const abs = try std.fs.path.join(testing.allocator, &.{ root, "big.txt" });
    defer testing.allocator.free(abs);
    try writeFileBytes(io, abs, content);

    const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_oneline_big/big.txt\"}");
    defer testing.allocator.free(r.content);
    defer if (r.display) |d| testing.allocator.free(d);
    try testing.expect(!r.is_error);
    // 应说明行被字节截断，且不得给出会越界的 offset 续读提示。
    try testing.expect(std.mem.indexOf(u8, r.content, "50.0KB") != null);
    try testing.expect(std.mem.indexOf(u8, r.content, "Use offset") == null);
    try testing.expect(std.mem.indexOf(u8, r.content, "No further lines") != null);

    // 按模型可能采取的下一步请求 offset=2，应当明确报越界（而不是静默返回空）。
    const r2 = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_oneline_big/big.txt\",\"offset\":2}");
    defer testing.allocator.free(r2.content);
    defer if (r2.display) |d| testing.allocator.free(d);
    try testing.expect(r2.is_error);
}

test "tools: read 行号前缀（绝对行号；offset/无尾换行/空文件边界）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_read_lines";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);
    makeDirs(io, root);

    // 整文件：每行 "N: 内容"，绝对行号从 1 起
    {
        const f = try std.fs.path.join(testing.allocator, &.{ root, "three.txt" });
        defer testing.allocator.free(f);
        try writeFileBytes(io, f, "alpha\nbeta\ngamma\n");
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_read_lines/three.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("1: alpha\n2: beta\n3: gamma\n", r.content);
    }

    // offset=2 → 行号是文件绝对行号（2 起），不是从 1 重新计数
    {
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_read_lines/three.txt\",\"offset\":2}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("2: beta\n3: gamma\n", r.content);
    }

    // 无尾换行的最后一行也要有行号且不丢内容
    {
        const f = try std.fs.path.join(testing.allocator, &.{ root, "noeol.txt" });
        defer testing.allocator.free(f);
        try writeFileBytes(io, f, "one\ntwo");
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_read_lines/noeol.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("1: one\n2: two", r.content);
    }

    // 截断提示的行号与编号一致（limit=1 在 offset=2 处）
    {
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_read_lines/three.txt\",\"offset\":2,\"limit\":1}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expectEqualStrings("2: beta\n\n[Showing lines 2-2 of 3. Use offset=3 to continue.]", r.content);
    }

    // 空文件：显式提示（避免与"读取失败"混淆）、不报错
    {
        const f = try std.fs.path.join(testing.allocator, &.{ root, "empty.txt" });
        defer testing.allocator.free(f);
        try writeFileBytes(io, f, "");
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_read_lines/empty.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expectEqualStrings("(empty file: skynet_test_read_lines/empty.txt)", r.content);
    }

    // 二进制文件（含 NUL 字节）：不输出乱码，提示用 bash 兜底
    {
        const f = try std.fs.path.join(testing.allocator, &.{ root, "bin.dat" });
        defer testing.allocator.free(f);
        try writeFileBytes(io, f, "\x00\x01\x02ABC\xff\xfe\x00\x00");
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_read_lines/bin.dat\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.content, "binary") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "10 bytes") != null);
        // 不应包含原始乱码内容
        try testing.expect(std.mem.indexOf(u8, r.content, "ABC") == null);
    }

    // 单行大文件（首行超 50KB）：编号仍存在，字节截断提示保留
    {
        const f = try std.fs.path.join(testing.allocator, &.{ root, "big.txt" });
        defer testing.allocator.free(f);
        const huge = try testing.allocator.alloc(u8, 90 * 1024);
        defer testing.allocator.free(huge);
        @memset(huge, 'x');
        try writeFileBytes(io, f, huge);
        const r = try execute(testing.allocator, io, cwd, "read", "{\"path\":\"skynet_test_read_lines/big.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.startsWith(u8, r.content, "1: x"));
        try testing.expect(std.mem.indexOf(u8, r.content, "No further lines") != null);
    }
}

test "tools: grep 锚点与空行（零宽匹配）" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_grep_anchor";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    {
        const r = try execute(testing.allocator, io, cwd, "write", "{\"path\":\"skynet_test_grep_anchor/a.txt\",\"content\":\"one\\n\\ntwo\\n\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(!r.is_error);
    }

    // ^$ 应匹配空行（第 2 行）
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"^$\",\"path\":\"skynet_test_grep_anchor/a.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "Line 2:") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "Line 1:") == null);
        try testing.expect(std.mem.indexOf(u8, r.content, "Line 3:") == null);
    }
    // ^ 应匹配每一行（3 行）
    {
        const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"^\",\"path\":\"skynet_test_grep_anchor/a.txt\"}");
        defer testing.allocator.free(r.content);
        defer if (r.display) |d| testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, r.content, "Line 1:") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "Line 2:") != null);
        try testing.expect(std.mem.indexOf(u8, r.content, "Line 3:") != null);
    }
}

test "tools: grep 因字节上限截断时提示不再误报为匹配数上限" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const cwd = try std.process.currentPathAlloc(io, testing.allocator);
    defer testing.allocator.free(cwd);

    const root_name = "skynet_test_grep_bytes";
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, root_name });
    defer testing.allocator.free(root);
    removeTree(io, testing.allocator, root);
    defer removeTree(io, testing.allocator, root);

    // 200 行 × 500 字符：命中数(200)远小于 limit(5000)，必然先撞上 50KB 字节上限
    const nlines: usize = 200;
    const line_len: usize = 500;
    const content = try testing.allocator.alloc(u8, nlines * (line_len + 1));
    defer testing.allocator.free(content);
    var i: usize = 0;
    while (i < nlines) : (i += 1) {
        @memset(content[i * (line_len + 1) ..][0..line_len], 'z');
        content[i * (line_len + 1) + line_len] = '\n';
    }
    const abs = try std.fs.path.join(testing.allocator, &.{ root, "big.txt" });
    defer testing.allocator.free(abs);
    try writeFileBytes(io, abs, content);

    const r = try execute(testing.allocator, io, cwd, "grep", "{\"pattern\":\"z\",\"path\":\"skynet_test_grep_bytes/big.txt\",\"literal\":true,\"limit\":5000}");
    defer testing.allocator.free(r.content);
    defer if (r.display) |d| testing.allocator.free(d);
    try testing.expect(std.mem.indexOf(u8, r.content, "truncated at 50.0KB") != null);
    try testing.expect(std.mem.indexOf(u8, r.content, "matches limit reached") == null);
}
