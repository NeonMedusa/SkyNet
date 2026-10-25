//! HTML → Markdown / 纯文本转换器（webfetch 用，零依赖单遍扫描）。
//!
//! 设计要点：
//! - 单遍扫描标签/文本/注释；属性值零拷贝（切片指向输入，不分配）
//! - 跳过 script/style/noscript/iframe/object/embed/template/svg/head 内容
//! - 块元素产生空行分隔；行内元素（strong/em/code/a）包标记
//! - 链接在闭合时回填：[text](href)（嵌套在行内元素里也能工作）
//! - 表格：首行为表头 + "| --- |" 分隔行；单元格走行内渲染
//! - 实体：常用命名实体 + 数字实体（&#123; / &#x1F600;）解码
//! - 空白：正文折叠为单空格；<pre> 内原样保留
//! - 输出结尾归一：行尾空格去除、3+ 连续换行收敛为 2
const std = @import("std");

pub const Mode = enum { markdown, text };

const max_attrs = 64;

const Attr = struct {
    name: []const u8,
    value: []const u8 = "",
};

pub fn convert(a: std.mem.Allocator, html: []const u8, mode: Mode) error{OutOfMemory}![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var st = State{
        .a = a,
        .out = &out,
        .mode = mode,
    };
    defer st.deinit();
    // 主内容提取：优先 <main> 子树（去导航/侧栏/页脚噪音）；找不到则整页转换
    try st.parse(extractMain(html) orelse html);
    return finishOut(a, &out);
}

fn finishOut(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}![]u8 {
    // 行尾空格去除 + 连续空行收敛 + 首尾空白清理
    var res: std.ArrayListUnmanaged(u8) = .empty;
    errdefer res.deinit(a);
    const src = out.items;
    var i: usize = 0;
    var newlines: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '\n') {
            newlines += 1;
            continue;
        }
        if (newlines > 0) {
            // 去掉上一行行尾的空格/制表
            while (res.items.len > 0 and (res.items[res.items.len - 1] == ' ' or res.items[res.items.len - 1] == '\t')) {
                res.items.len -= 1;
            }
            const want: usize = if (res.items.len == 0) 0 else @min(newlines, 2);
            var k: usize = 0;
            while (k < want) : (k += 1) try res.append(a, '\n');
            newlines = 0;
        }
        try res.append(a, c);
    }
    while (res.items.len > 0 and (res.items[res.items.len - 1] == ' ' or res.items[res.items.len - 1] == '\t' or res.items[res.items.len - 1] == '\n')) {
        res.items.len -= 1;
    }
    out.deinit(a);
    return res.toOwnedSlice(a);
}

const ListLevel = struct {
    ordered: bool,
    index: usize = 1,
};

const LinkFrame = struct {
    out_len: usize,
    href: []const u8,
};

const max_table_cols = 32;

const CarriedCell = struct {
    text: []u8,
    /// 还需要延续到后续多少行（0 = 本行已用完）
    left: usize,
};

const TableState = struct {
    row: std.ArrayListUnmanaged(u8) = .empty,
    rows: usize = 0,
    cols: usize = 0,
    cur_cols: usize = 0,
    /// 行内已产出单元格数（含 colspan 补格与 rowspan 延续格）
    emit_count: usize = 0,
    /// 下一个可用列号（colspan/rowspan 占用的列会被跳过）
    next_col: usize = 0,
    /// 当前真实单元格文本在 row 内的起点
    cell_start: usize = 0,
    cur_rowspan: usize = 1,
    cur_colspan: usize = 1,
    /// rowspan 延续：按列存 { 文本, 余下续行数 }
    carry: [max_table_cols]?CarriedCell = @splat(null),
};

const skip_tags = [_][]const u8{ "script", "style", "noscript", "iframe", "object", "embed", "template", "svg", "math", "head" };
const block_tags = [_][]const u8{
    "address", "article", "aside", "details", "dialog", "div", "dl", "fieldset", "figcaption",
    "figure", "footer", "form", "header", "main", "nav", "p", "section", "summary", "body", "html",
};

const State = struct {
    a: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    mode: Mode,
    skip_depth: usize = 0,
    skip_name: []const u8 = "",
    pre: bool = false,
    pre_lang: [24]u8 = undefined,
    pre_lang_len: usize = 0,
    in_pre_fence: bool = false,
    /// 围栏语言标注回填位置（写入 "```" 之后的位置；<code class> 晚到时回填）
    fence_lang_pos: usize = 0,
    lists: std.ArrayListUnmanaged(ListLevel) = .empty,
    bq: usize = 0,
    strong: usize = 0,
    em: usize = 0,
    code: usize = 0,
    links: std.ArrayListUnmanaged(LinkFrame) = .empty,
    table: ?*TableState = null,
    pending_space: bool = false,
    li_open: bool = false,
    lower_buf: [32]u8 = undefined,
    saved_out: ?*std.ArrayListUnmanaged(u8) = null,

    fn deinit(self: *State) void {
        self.lists.deinit(self.a);
        self.links.deinit(self.a);
        if (self.table) |t| {
            self.freeCarry(t);
            t.row.deinit(self.a);
            self.a.destroy(t);
        }
    }

    // ── 输出原语 ──

    fn outEmptyOrLineStart(self: *State) bool {
        return self.out.items.len == 0 or self.out.items[self.out.items.len - 1] == '\n';
    }

    fn ensureNewline(self: *State) !void {
        self.pending_space = false;
        if (self.out.items.len == 0) return;
        if (self.out.items[self.out.items.len - 1] != '\n') try self.out.append(self.a, '\n');
    }

    fn ensureBlankLine(self: *State) !void {
        if (self.mode == .text) return self.ensureNewline();
        self.pending_space = false;
        if (self.out.items.len == 0) return;
        try self.ensureNewline();
        if (self.out.items.len >= 2 and self.out.items[self.out.items.len - 2] == '\n') return;
        try self.out.append(self.a, '\n');
    }

    fn blockStart(self: *State) !void {
        try self.ensureBlankLine();
        try self.linePrefix();
    }

    fn linePrefix(self: *State) !void {
        if (self.bq == 0 or self.mode == .text) return;
        var k: usize = 0;
        while (k < self.bq) : (k += 1) try self.out.appendSlice(self.a, "> ");
    }

    fn inlineSpace(self: *State) void {
        if (self.out.items.len == 0) return;
        if (self.outEmptyOrLineStart()) return;
        self.pending_space = true;
    }

    fn flushSpace(self: *State) !void {
        if (self.pending_space) {
            self.pending_space = false;
            const last = if (self.out.items.len > 0) self.out.items[self.out.items.len - 1] else 0;
            if (last != ' ' and last != '\n' and last != 0) try self.out.append(self.a, ' ');
        }
    }

    fn appendInline(self: *State, s: []const u8) !void {
        if (s.len == 0) return;
        try self.flushSpace();
        try self.out.appendSlice(self.a, s);
    }

    fn appendMark(self: *State, s: []const u8) !void {
        if (self.mode == .text) return;
        if (self.table == null) try self.flushSpace();
        try self.out.appendSlice(self.a, s);
    }

    // ── 扫描 ──

    fn parse(self: *State, html: []const u8) !void {
        var i: usize = 0;
        while (i < html.len) {
            if (html[i] == '<') {
                if (std.mem.startsWith(u8, html[i..], "<!--")) {
                    const end = std.mem.find(u8, html[i + 4 ..], "-->") orelse {
                        i = html.len;
                        continue;
                    };
                    i += 4 + end + 3;
                    continue;
                }
                if (std.mem.startsWith(u8, html[i..], "<!")) {
                    const end = std.mem.findScalar(u8, html[i..], '>') orelse {
                        i = html.len;
                        continue;
                    };
                    i += end + 1;
                    continue;
                }
                if (std.mem.startsWith(u8, html[i..], "</")) {
                    var j = i + 2;
                    const ns = j;
                    while (j < html.len and isNameChar(html[j])) : (j += 1) {}
                    const name = html[ns..j];
                    const end = std.mem.findScalar(u8, html[j..], '>') orelse {
                        i = html.len;
                        continue;
                    };
                    i = j + end + 1;
                    if (name.len != 0) try self.endTag(lowerName(&self.lower_buf, name));
                    continue;
                }
                // 开始标签
                var j = i + 1;
                const ns = j;
                while (j < html.len and isNameChar(html[j])) : (j += 1) {}
                if (j == ns) {
                    i += 1;
                    continue;
                }
                const name_raw = html[ns..j];
                // 找标签结束（引号感知）
                var k = j;
                var quote: u8 = 0;
                while (k < html.len) : (k += 1) {
                    const c = html[k];
                    if (quote != 0) {
                        if (c == quote) quote = 0;
                    } else if (c == '"' or c == '\'') {
                        quote = c;
                    } else if (c == '>') break;
                }
                const tag_end = @min(k, html.len);
                const body = html[j..tag_end];
                const self_closing = body.len > 0 and body[body.len - 1] == '/';
                const name = lowerName(&self.lower_buf, name_raw);
                i = tag_end + 1;
                if (self_closing) {
                    try self.voidTag(name, body);
                } else {
                    try self.startTag(name, body);
                }
                continue;
            }
            const next = std.mem.findScalar(u8, html[i..], '<') orelse html.len - i;
            try self.text(html[i .. i + next]);
            i += next;
        }
        if (self.table) |t| try self.flushTable(t);
    }

    fn lowerName(buf: *[32]u8, name: []const u8) []const u8 {
        const n = @min(name.len, buf.len);
        for (name[0..n], 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
        return buf[0..n];
    }

    fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':';
    }

    // ── 文本 ──

    fn text(self: *State, raw: []const u8) !void {
        if (self.skip_depth > 0) return;
        if (self.in_pre_fence) {
            if (self.pre) {
                try self.preRaw(raw);
                return;
            }
            if (self.table == null) {
                try self.bodyText(raw);
                return;
            }
            // 表格单元格里的 <pre>：退化为普通文本
        }
        if (self.pre) {
            try self.preRaw(raw);
            return;
        }
        if (self.table != null) {
            return self.bodyText(raw);
        }
        try self.bodyText(raw);
    }

    fn preRaw(self: *State, raw: []const u8) !void {
        // pre 内：实体解码 + 原样保留（换行/空格不折叠）
        try self.decodeEntitiesInto(self.out, raw);
    }

    fn bodyText(self: *State, raw: []const u8) !void {
        // 折叠空白 + 实体解码
        var i: usize = 0;
        var pending_ws = false;
        var piece: std.ArrayListUnmanaged(u8) = .empty;
        defer piece.deinit(self.a);
        while (i < raw.len) {
            const c = raw[i];
            if (isWs(c)) {
                pending_ws = true;
                i += 1;
                continue;
            }
            if (pending_ws) {
                pending_ws = false;
                try self.emitWs();
            }
            // 收集到下一个空白或实体边界
            const start = i;
            while (i < raw.len and !isWs(raw[i]) and raw[i] != '&') : (i += 1) {}
            if (i > start) try self.appendInline(raw[start..i]);
            if (i < raw.len and raw[i] == '&') {
                try self.flushSpace();
                const consumed = try self.decodeOneEntity(self.out, raw[i..]);
                if (consumed == 0) {
                    try self.appendInline("&");
                    i += 1;
                } else {
                    i += consumed;
                }
            }
        }
        if (pending_ws) try self.emitWs();
    }

    fn emitWs(self: *State) !void {
        // 块级开头不输出前导空白；相邻元素间最多一个空格
        if (self.table) |t| {
            _ = t;
            self.pending_space = true;
            return;
        }
        self.inlineSpace();
    }

    // ── 实体解码 ──

    fn decodeEntitiesInto(self: *State, dest: *std.ArrayListUnmanaged(u8), raw: []const u8) !void {
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '&') {
                const consumed = try self.decodeOneEntity(dest, raw[i..]);
                if (consumed > 0) {
                    i += consumed;
                    continue;
                }
            }
            // 普通字节：追加（检查 UTF-8 连续性——无效字节替换为 U+FFFD）
            const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
                try dest.append(self.a, 0xEF);
                try dest.append(self.a, 0xBF);
                try dest.append(self.a, 0xBD);
                i += 1;
                continue;
            };
            if (i + n > raw.len) {
                try dest.append(self.a, 0xEF);
                try dest.append(self.a, 0xBF);
                try dest.append(self.a, 0xBD);
                break;
            }
            try dest.appendSlice(self.a, raw[i .. i + n]);
            i += n;
        }
    }

    /// 解码一个实体（raw 以 '&' 开头）；返回消费的字节数，0 = 不是实体。
    fn decodeOneEntity(self: *State, dest: *std.ArrayListUnmanaged(u8), raw: []const u8) !usize {
        const semi = std.mem.findScalar(u8, raw[0..@min(raw.len, 12)], ';') orelse return 0;
        if (semi < 2) return 0;
        const name = raw[1..semi];
        var cp: u21 = 0;
        if (name[0] == '#') {
            if (name.len >= 2 and (name[1] == 'x' or name[1] == 'X')) {
                cp = std.fmt.parseInt(u21, name[2..], 16) catch return 0;
            } else {
                cp = std.fmt.parseInt(u21, name[1..], 10) catch return 0;
            }
        } else {
            cp = namedEntity(name) orelse return 0;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch {
            try dest.appendSlice(self.a, "\u{FFFD}");
            return semi + 1;
        };
        try dest.appendSlice(self.a, buf[0..n]);
        return semi + 1;
    }

    fn namedEntity(name: []const u8) ?u21 {
        const map = [_]struct { n: []const u8, c: u21 }{
            .{ .n = "amp", .c = '&' },       .{ .n = "lt", .c = '<' },
            .{ .n = "gt", .c = '>' },        .{ .n = "quot", .c = '"' },
            .{ .n = "apos", .c = '\'' },     .{ .n = "nbsp", .c = 0x00A0 },
            .{ .n = "mdash", .c = 0x2014 },  .{ .n = "ndash", .c = 0x2013 },
            .{ .n = "hellip", .c = 0x2026 }, .{ .n = "laquo", .c = 0x00AB },
            .{ .n = "raquo", .c = 0x00BB },  .{ .n = "ldquo", .c = 0x201C },
            .{ .n = "rdquo", .c = 0x201D },  .{ .n = "lsquo", .c = 0x2018 },
            .{ .n = "rsquo", .c = 0x2019 },  .{ .n = "middot", .c = 0x00B7 },
            .{ .n = "bull", .c = 0x2022 },   .{ .n = "copy", .c = 0x00A9 },
            .{ .n = "reg", .c = 0x00AE },    .{ .n = "trade", .c = 0x2122 },
            .{ .n = "times", .c = 0x00D7 },  .{ .n = "divide", .c = 0x00F7 },
            .{ .n = "plusmn", .c = 0x00B1 }, .{ .n = "deg", .c = 0x00B0 },
            .{ .n = "sect", .c = 0x00A7 },   .{ .n = "para", .c = 0x00B6 },
            .{ .n = "dagger", .c = 0x2020 }, .{ .n = "euro", .c = 0x20AC },
            .{ .n = "pound", .c = 0x00A3 },  .{ .n = "yen", .c = 0x00A5 },
            .{ .n = "cent", .c = 0x00A2 },   .{ .n = "szlig", .c = 0x00DF },
            .{ .n = "agrave", .c = 0x00E0 }, .{ .n = "aacute", .c = 0x00E1 },
            .{ .n = "eacute", .c = 0x00E9 }, .{ .n = "egrave", .c = 0x00E8 },
            .{ .n = "iacute", .c = 0x00ED }, .{ .n = "oacute", .c = 0x00F3 },
            .{ .n = "uacute", .c = 0x00FA }, .{ .n = "ntilde", .c = 0x00F1 },
            .{ .n = "uuml", .c = 0x00FC },   .{ .n = "ouml", .c = 0x00F6 },
            .{ .n = "auml", .c = 0x00E4 },   .{ .n = "szlig2", .c = 0x00DF },
            .{ .n = "thinsp", .c = 0x2009 }, .{ .n = "ensp", .c = 0x2002 },
            .{ .n = "emsp", .c = 0x2003 },   .{ .n = "zwnj", .c = 0x200C },
            .{ .n = "zwj", .c = 0x200D },    .{ .n = "larr", .c = 0x2190 },
            .{ .n = "rarr", .c = 0x2192 },   .{ .n = "uarr", .c = 0x2191 },
            .{ .n = "darr", .c = 0x2193 },   .{ .n = "harr", .c = 0x2194 },
            .{ .n = "iexcl", .c = 0x00A1 },  .{ .n = "iquest", .c = 0x00BF },
            .{ .n = "micro", .c = 0x00B5 },  .{ .n = "frac12", .c = 0x00BD },
            .{ .n = "frac14", .c = 0x00BC }, .{ .n = "frac34", .c = 0x00BE },
            .{ .n = "sup2", .c = 0x00B2 },   .{ .n = "sup3", .c = 0x00B3 },
            .{ .n = "ne", .c = 0x2260 },     .{ .n = "le", .c = 0x2264 },
            .{ .n = "ge", .c = 0x2265 },     .{ .n = "infin", .c = 0x221E },
            .{ .n = "check", .c = 0x2713 },  .{ .n = "cross", .c = 0x2717 },
        };
        for (map) |e| {
            if (std.mem.eql(u8, e.n, name)) return e.c;
        }
        return null;
    }

    // ── 标签 ──

    fn attrValue(body: []const u8, want: []const u8) []const u8 {
        var i: usize = 0;
        while (i < body.len) {
            while (i < body.len and (isWs(body[i]) or body[i] == '/')) i += 1;
            const ns = i;
            while (i < body.len and body[i] != '=' and !isWs(body[i]) and body[i] != '/') i += 1;
            const name = body[ns..i];
            while (i < body.len and isWs(body[i])) i += 1;
            if (i < body.len and body[i] == '=') {
                i += 1;
                while (i < body.len and isWs(body[i])) i += 1;
                var val: []const u8 = "";
                if (i < body.len and (body[i] == '"' or body[i] == '\'')) {
                    const q = body[i];
                    i += 1;
                    const vs = i;
                    while (i < body.len and body[i] != q) i += 1;
                    val = body[vs..i];
                    if (i < body.len) i += 1;
                } else {
                    const vs = i;
                    while (i < body.len and !isWs(body[i]) and body[i] != '/') i += 1;
                    val = body[vs..i];
                }
                if (std.ascii.eqlIgnoreCase(name, want)) return val;
            } else if (std.ascii.eqlIgnoreCase(name, want)) {
                return "";
            }
        }
        return "";
    }

    fn startTag(self: *State, name: []const u8, body: []const u8) !void {
        for (skip_tags) |s| {
            if (std.mem.eql(u8, s, name)) {
                if (self.skip_depth == 0) self.skip_name = name;
                self.skip_depth += 1;
                return;
            }
        }
        if (self.skip_depth > 0) return;

        if (isHeading(name)) {
            try self.blockStart();
            if (self.mode == .markdown) {
                const lvl: usize = name[1] - '0';
                try self.out.appendNTimes(self.a, '#', lvl);
                try self.out.append(self.a, ' ');
            }
            return;
        }
        if (isBlock(name)) {
            try self.blockStart();
            return;
        }
        if (std.mem.eql(u8, name, "br")) {
            if (self.pre) {
                try self.out.append(self.a, '\n');
            } else {
                try self.ensureNewline();
                if (self.bq > 0) try self.linePrefix();
            }
            return;
        }
        if (std.mem.eql(u8, name, "hr")) {
            try self.blockStart();
            if (self.mode == .markdown) try self.out.appendSlice(self.a, "---");
            try self.ensureBlankLine();
            return;
        }
        if (std.mem.eql(u8, name, "pre")) {
            try self.blockStart();
            self.pre = true;
            self.pre_lang_len = 0;
            const cl = attrValue(body, "class");
            if (cl.len > 0) {
                var lang = cl;
                if (std.mem.startsWith(u8, lang, "language-")) lang = lang["language-".len..];
                if (std.mem.startsWith(u8, lang, "lang-")) lang = lang["lang-".len..];
                const n = @min(lang.len, self.pre_lang.len);
                @memcpy(self.pre_lang[0..n], lang[0..n]);
                self.pre_lang_len = n;
            }
            if (self.mode == .markdown) {
                try self.out.appendSlice(self.a, "```");
                try self.out.appendSlice(self.a, self.pre_lang[0..self.pre_lang_len]);
                self.fence_lang_pos = self.out.items.len;
                try self.out.append(self.a, '\n');
                self.in_pre_fence = true;
            }
            return;
        }
        if (std.mem.eql(u8, name, "code") and self.pre) {
            // 常见写法：<pre><code class="language-x"> —— 语言在 code 上，回填围栏
            if (self.pre_lang_len == 0 and self.fence_lang_pos > 0) {
                const cl = attrValue(body, "class");
                if (cl.len > 0) {
                    var lang = cl;
                    if (std.mem.startsWith(u8, lang, "language-")) lang = lang["language-".len..];
                    if (std.mem.startsWith(u8, lang, "lang-")) lang = lang["lang-".len..];
                    if (lang.len > 0 and lang.len <= 24) {
                        self.out.insertSlice(self.a, self.fence_lang_pos, lang) catch {};
                        self.fence_lang_pos = 0;
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, name, "code") and !self.pre) {
            if (self.mode == .markdown) {
                self.code += 1;
                try self.appendMark("`");
            }
            return;
        }
        if (std.mem.eql(u8, name, "strong") or std.mem.eql(u8, name, "b")) {
            self.strong += 1;
            if (self.mode == .markdown) try self.appendMark("**");
            return;
        }
        if (std.mem.eql(u8, name, "em") or std.mem.eql(u8, name, "i")) {
            self.em += 1;
            if (self.mode == .markdown) try self.appendMark("*");
            return;
        }
        if (std.mem.eql(u8, name, "a")) {
            const href = attrValue(body, "href");
            try self.links.append(self.a, .{ .out_len = self.linkOutLen(), .href = href });
            return;
        }
        if (std.mem.eql(u8, name, "img")) {
            const src = attrValue(body, "src");
            const alt = attrValue(body, "alt");
            if (self.mode == .markdown and src.len > 0 and !isBadUrl(src)) {
                try self.flushSpace();
                try self.out.appendSlice(self.a, "![");
                try self.decodeEntitiesInto(self.out, alt);
                try self.out.appendSlice(self.a, "](");
                try self.out.appendSlice(self.a, src);
                try self.out.append(self.a, ')');
            } else if (self.mode == .text and alt.len > 0) {
                try self.appendInline(alt);
            }
            return;
        }
        if (std.mem.eql(u8, name, "ul") or std.mem.eql(u8, name, "ol")) {
            try self.listStart(std.mem.eql(u8, name, "ol"));
            return;
        }
        if (std.mem.eql(u8, name, "li")) {
            try self.listItemStart();
            return;
        }
        if (std.mem.eql(u8, name, "blockquote")) {
            try self.blockStart();
            self.bq += 1;
            return;
        }
        if (std.mem.eql(u8, name, "table")) {
            if (self.table != null) return; // 嵌套表：忽略内层
            try self.blockStart();
            const t = try self.a.create(TableState);
            t.* = .{};
            self.table = t;
            return;
        }
        if (std.mem.eql(u8, name, "tr")) {
            if (self.table) |t| {
                t.row.clearRetainingCapacity();
                t.cur_cols = 0;
                t.emit_count = 0;
                t.next_col = 0;
            }
            return;
        }
        if (std.mem.eql(u8, name, "td") or std.mem.eql(u8, name, "th")) {
            if (self.table) |t| {
                // 上一格可能未闭合（HTML 允许省略 </td>）：先隐式关闭
                try self.closeCell(t);
                try self.drainCarryColumns(t);
                if (t.emit_count > 0) try t.row.appendSlice(self.a, " | ");
                t.cell_start = t.row.items.len;
                self.saved_out = self.out;
                self.out = &t.row;
                t.emit_count += 1;
                t.cur_cols += 1;
                t.cur_rowspan = parseSpan(attrValue(body, "rowspan"));
                t.cur_colspan = parseSpan(attrValue(body, "colspan"));
            }
            return;
        }
        // 其余标签（span/strong 已处理/自定义元素等）：透明
    }

    fn linkOutLen(self: *State) usize {
        return self.out.items.len;
    }

    fn endTag(self: *State, name: []const u8) !void {
        if (self.skip_depth > 0) {
            if (std.mem.eql(u8, name, self.skip_name) or skip_name_matches(name)) {
                self.skip_depth -= 1;
                if (self.skip_depth == 0) self.skip_name = "";
            }
            return;
        }
        if (isHeading(name) or isBlock(name)) {
            try self.blockEnd();
            return;
        }
        if (std.mem.eql(u8, name, "pre")) {
            if (self.pre) {
                self.pre = false;
                if (self.mode == .markdown and self.in_pre_fence) {
                    self.in_pre_fence = false;
                    if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] != '\n') try self.out.append(self.a, '\n');
                    try self.out.appendSlice(self.a, "```");
                }
                try self.ensureBlankLine();
            }
            return;
        }
                if (std.mem.eql(u8, name, "code") and !self.pre) {
            if (self.mode == .markdown) {
                if (self.code > 0) self.code -= 1;
                try self.appendMark("`");
            }
            return;
        }
        if (std.mem.eql(u8, name, "strong") or std.mem.eql(u8, name, "b")) {
            if (self.strong > 0) self.strong -= 1;
            if (self.mode == .markdown) try self.appendMark("**");
            return;
        }
        if (std.mem.eql(u8, name, "em") or std.mem.eql(u8, name, "i")) {
            if (self.em > 0) self.em -= 1;
            if (self.mode == .markdown) try self.appendMark("*");
            return;
        }
        if (std.mem.eql(u8, name, "a")) {
            self.linkClose();
            return;
        }
        if (std.mem.eql(u8, name, "ul") or std.mem.eql(u8, name, "ol")) {
            self.listEnd();
            return;
        }
        if (std.mem.eql(u8, name, "li")) {
            try self.listItemEnd();
            return;
        }
        if (std.mem.eql(u8, name, "blockquote")) {
            if (self.bq > 0) self.bq -= 1;
            try self.ensureBlankLine();
            return;
        }
        if (std.mem.eql(u8, name, "td") or std.mem.eql(u8, name, "th")) {
            if (self.table) |t| try self.closeCell(t);
            return;
        }
        if (std.mem.eql(u8, name, "tr")) {
            if (self.table) |t| {
                try self.closeCell(t);
                try self.drainCarryColumns(t);
                try self.flushTableRow(t);
                t.emit_count = 0;
                t.next_col = 0;
            }
            return;
        }
        if (std.mem.eql(u8, name, "table")) {
            if (self.table) |t| {
                try self.closeCell(t);
                try self.flushTable(t);
                self.freeCarry(t);
                t.row.deinit(self.a);
                self.a.destroy(t);
                self.table = null;
                try self.ensureBlankLine();
            }
            return;
        }
    }

    fn skip_name_matches(name: []const u8) bool {
        for (skip_tags) |s| {
            if (std.mem.eql(u8, s, name)) return true;
        }
        return false;
    }

    fn blockEnd(self: *State) !void {
        try self.blockStart();
    }

    fn linkClose(self: *State) void {
        const frame = self.links.pop() orelse return;
        if (self.mode != .markdown) return;
        if (frame.href.len == 0 or isBadUrl(frame.href)) return;
        const start = frame.out_len;
        if (start >= self.out.items.len) return;
        // 去掉链接文本两端的空白
        const seg = self.out.items[start..];
        const trimmed = std.mem.trim(u8, seg, " \t\n");
        if (trimmed.len == 0) return;
        const a = self.a;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        const needs_angle = std.mem.findScalar(u8, frame.href, ' ') != null or std.mem.findScalar(u8, frame.href, '(') != null;
        buf.append(a, '[') catch return;
        buf.appendSlice(a, trimmed) catch return;
        buf.appendSlice(a, "](") catch return;
        if (needs_angle) buf.append(a, '<') catch return;
        buf.appendSlice(a, frame.href) catch return;
        if (needs_angle) buf.append(a, '>') catch return;
        buf.append(a, ')') catch return;
        self.out.shrinkRetainingCapacity(start);
        self.out.appendSlice(a, buf.items) catch return;
    }

    fn isBadUrl(u: []const u8) bool {
        if (std.mem.startsWith(u8, u, "javascript:")) return true;
        if (std.mem.startsWith(u8, u, "#")) return true;
        return false;
    }

    // ── 列表 ──

    fn listStart(self: *State, ordered: bool) !void {
        try self.lists.append(self.a, .{ .ordered = ordered });
        if (self.mode == .markdown and !self.outEmptyOrLineStart()) try self.ensureNewline();
        try self.linePrefix();
    }

    fn listEnd(self: *State) void {
        _ = self.lists.pop();
    }

    fn listItemStart(self: *State) !void {
        try self.ensureNewline();
        if (self.mode == .markdown) {
            const depth = if (self.lists.items.len > 0) self.lists.items.len - 1 else 0;
            var k: usize = 0;
            while (k < depth) : (k += 1) try self.out.appendSlice(self.a, "  ");
            if (self.lists.items.len > 0 and self.lists.items[self.lists.items.len - 1].ordered) {
                const lvl = &self.lists.items[self.lists.items.len - 1];
                var num: [12]u8 = undefined;
                const s = std.fmt.bufPrint(&num, "{d}. ", .{lvl.index}) catch "1. ";
                lvl.index += 1;
                try self.out.appendSlice(self.a, s);
            } else {
                try self.out.appendSlice(self.a, "- ");
            }
        }
        self.li_open = true;
    }

    fn listItemEnd(self: *State) !void {
        if (self.mode == .markdown) {
            if (!self.outEmptyOrLineStart()) try self.ensureNewline();
        } else {
            try self.ensureNewline();
        }
        self.li_open = false;
    }

    // ── 表格 ──

    /// 追加一个单元格（含分隔符）到当前行
    fn emitCell(self: *State, t: *TableState, cell_text: []const u8) !void {
        if (t.emit_count > 0) try t.row.appendSlice(self.a, " | ");
        try t.row.appendSlice(self.a, cell_text);
        t.emit_count += 1;
        t.cur_cols += 1;
    }

    /// 关闭当前单元格（幂等）：恢复输出指针、登记 rowspan、colspan 补格、推进列游标。
    /// 未闭合 <td>（省略 </td> 的合法 HTML）由新 <td>/</tr>/</table> 触发隐式关闭。
    fn closeCell(self: *State, t: *TableState) !void {
        const so = self.saved_out orelse return;
        self.out = so;
        self.saved_out = null;
        // rowspan：先复制单元格文本（colspan 补格会追加 row、可能重分配）
        if (t.cur_rowspan > 1 and t.next_col < max_table_cols) {
            const owned = try self.a.dupe(u8, t.row.items[t.cell_start..]);
            if (t.carry[t.next_col]) |old| self.a.free(old.text);
            t.carry[t.next_col] = .{ .text = owned, .left = t.cur_rowspan - 1 };
        }
        // colspan：补空列对齐表头
        var extra = t.cur_colspan;
        while (extra > 1) : (extra -= 1) try self.emitCell(t, "");
        t.next_col += t.cur_colspan;
        t.cur_rowspan = 1;
        t.cur_colspan = 1;
    }

    /// 把 next_col 处连续的 rowspan 延续格吐出到当前行（推进列游标）
    fn drainCarryColumns(self: *State, t: *TableState) !void {
        while (t.next_col < max_table_cols) {
            const cell = t.carry[t.next_col] orelse return;
            try self.emitCell(t, cell.text);
            if (cell.left <= 1) {
                self.a.free(cell.text);
                t.carry[t.next_col] = null;
            } else {
                t.carry[t.next_col] = .{ .text = cell.text, .left = cell.left - 1 };
            }
            t.next_col += 1;
        }
    }

    fn freeCarry(self: *State, t: *TableState) void {
        for (&t.carry) |*slot| {
            if (slot.*) |c| {
                self.a.free(c.text);
                slot.* = null;
            }
        }
    }

    fn flushTableRow(self: *State, t: *TableState) !void {
        if (t.row.items.len == 0) return;
        if (self.mode == .markdown) {
            try self.ensureNewline();
            try self.out.appendSlice(self.a, "| ");
            try self.out.appendSlice(self.a, t.row.items);
            try self.out.append(self.a, ' ');
            try self.out.append(self.a, '|');
            try self.out.append(self.a, '\n');
            if (t.rows == 0) {
                t.cols = t.cur_cols;
                if (t.cols > 0) {
                    try self.out.appendSlice(self.a, "| ");
                    var k: usize = 0;
                    while (k < t.cols) : (k += 1) {
                        if (k > 0) try self.out.appendSlice(self.a, " | ");
                        try self.out.appendSlice(self.a, "---");
                    }
                    try self.out.appendSlice(self.a, " |\n");
                }
            }
        } else {
            try self.ensureNewline();
            try self.out.appendSlice(self.a, t.row.items);
            try self.out.append(self.a, '\n');
        }
        t.rows += 1;
    }

    fn flushTable(self: *State, t: *TableState) !void {
        try self.flushTableRow(t);
    }

    // ── 空元素 ──

    fn voidTag(self: *State, name: []const u8, body: []const u8) !void {
        if (std.mem.eql(u8, name, "br")) {
            if (self.pre) {
                try self.out.append(self.a, '\n');
            } else {
                try self.ensureNewline();
                if (self.bq > 0) try self.linePrefix();
            }
            return;
        }
        if (std.mem.eql(u8, name, "hr")) {
            try self.blockStart();
            if (self.mode == .markdown) try self.out.appendSlice(self.a, "---");
            try self.ensureBlankLine();
            return;
        }
        if (std.mem.eql(u8, name, "img")) {
            const src = attrValue(body, "src");
            const alt = attrValue(body, "alt");
            if (self.mode == .markdown and src.len > 0 and !isBadUrl(src)) {
                try self.flushSpace();
                try self.out.appendSlice(self.a, "![");
                try self.decodeEntitiesInto(self.out, alt);
                try self.out.appendSlice(self.a, "](");
                try self.out.appendSlice(self.a, src);
                try self.out.append(self.a, ')');
            } else if (self.mode == .text and alt.len > 0) {
                try self.appendInline(alt);
            }
            return;
        }
        // 其他自闭合元素忽略
    }
};

/// 解析 rowspan/colspan：合法范围 1..max_table_cols，其余（0/负数/非数字）退化 1。
fn parseSpan(raw: []const u8) usize {
    if (raw.len == 0) return 1;
    const n = std.fmt.parseInt(usize, raw, 10) catch return 1;
    if (n < 1 or n > max_table_cols) return 1;
    return n;
}

/// 提取 <main>…</main> 的内容（大小写不敏感；HTML 不允许嵌套 main，取首个闭合即可）。
/// 找不到返回 null（调用方转换整页）。
pub fn extractMain(html: []const u8) ?[]const u8 {
    const open_idx = std.ascii.findIgnoreCase(html, "<main") orelse return null;
    const after_name = open_idx + "<main".len;
    // 标签名后面必须是非名字字符（避免 <main-x>）
    if (after_name < html.len) {
        const c = html[after_name];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':') return null;
    }
    const tag_end = std.mem.findScalar(u8, html[after_name..], '>') orelse return null;
    const content_start = after_name + tag_end + 1;
    const close_idx = std.ascii.findIgnoreCase(html[content_start..], "</main") orelse return null;
    return html[content_start .. content_start + close_idx];
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isHeading(name: []const u8) bool {
    if (name.len != 2) return false;
    return name[0] == 'h' and name[1] >= '1' and name[1] <= '6';
}

fn isBlock(name: []const u8) bool {
    for (block_tags) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

// ── 测试 ──

const testing = std.testing;

test "html→md：标题/段落/加粗/链接/行内码" {
    const html =
        \\<html><head><title>T</title><script>var x=1;</script></head>
        \\<body><h1>标题</h1><p>这是 <strong>粗体</strong> 和 <a href="https://example.com">链接</a>，还有 <code>x=1</code>。</p></body></html>
    ;
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "# 标题") != null);
    try testing.expect(std.mem.indexOf(u8, md, "**粗体**") != null);
    try testing.expect(std.mem.indexOf(u8, md, "[链接](https://example.com)") != null);
    try testing.expect(std.mem.indexOf(u8, md, "`x=1`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "script") == null); // script 被跳过
}

test "html→md：列表/嵌套" {
    const html = "<ul><li>a</li><li>b<ul><li>b1</li></ul></li></ul><ol><li>one</li><li>two</li></ol>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "- a") != null);
    try testing.expect(std.mem.indexOf(u8, md, "- b") != null);
    try testing.expect(std.mem.indexOf(u8, md, "  - b1") != null);
    try testing.expect(std.mem.indexOf(u8, md, "1. one") != null);
    try testing.expect(std.mem.indexOf(u8, md, "2. two") != null);
}

test "html→md：pre 代码块保留空白与语言" {
    const html = "<pre class=\"language-zig\"><code>const a = 1;\nif (a) {\n    x();\n}</code></pre>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "```zig") != null);
    try testing.expect(std.mem.indexOf(u8, md, "    x();") != null);
}

test "html→md：pre>code 上的语言回填" {
    const html = "<pre><code class=\"language-rust\">fn main() {}</code></pre>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "```rust") != null);
}

test "html→md：表格" {
    const html = "<table><tr><th>名</th><th>值</th></tr><tr><td>a</td><td>1</td></tr></table>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "| 名 | 值 |") != null);
    try testing.expect(std.mem.indexOf(u8, md, "| --- | --- |") != null);
    try testing.expect(std.mem.indexOf(u8, md, "| a | 1 |") != null);
}

test "html→md：<main> 主内容提取（去导航噪音）" {
    const html =
        \\<html><body><nav>导航噪音</nav><main><h1>正文标题</h1><p>正文内容</p></main><footer>页脚</footer></body></html>
    ;
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "正文标题") != null);
    try testing.expect(std.mem.indexOf(u8, md, "正文内容") != null);
    try testing.expect(std.mem.indexOf(u8, md, "导航噪音") == null);
    try testing.expect(std.mem.indexOf(u8, md, "页脚") == null);
}

test "html→md：无 main 时整页转换；<main-x> 不算" {
    const html = "<body><main-x>不是主内容</main-x><p>段落</p></body>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "段落") != null);
    try testing.expect(std.mem.indexOf(u8, md, "不是主内容") != null);
}

test "html→md：rowspan 延续单元格" {
    const html =
        \\<table><tr><th>OS</th><th>Arch</th><th>Size</th></tr>
        \\<tr><td rowspan="2">Source</td><td>tar</td><td>22</td></tr>
        \\<tr><td>boot</td><td>54</td></tr></table>
    ;
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "| Source | tar | 22 |") != null);
    try testing.expect(std.mem.indexOf(u8, md, "| Source | boot | 54 |") != null);
}

test "html→md：colspan 补齐列" {
    const html = "<table><tr><th>a</th><th>b</th><th>c</th></tr><tr><td colspan=\"2\">wide</td><td>x</td></tr></table>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "| wide |  | x |") != null);
}

test "html→md：省略 </td> 的表格（HTML 合法）" {
    const html = "<table><tr><th>a<th>b<tr><td>1<td>2</table><p>后文</p>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "后文") != null);
}

test "html→md：非法 span 退化为 1" {
    const html = "<table><tr><td rowspan=\"abc\">a</td><td colspan=\"0\">b</td></tr></table>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "| a | b |") != null);
}

test "html→md：实体与数字实体" {
    const html = "<p>&amp; &lt; &gt; &nbsp;&#48;&#x41;&mdash;&hellip;</p>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "& < >") != null);
    try testing.expect(std.mem.indexOf(u8, md, "0A—…") != null);
}

test "html→text：去标签取文本" {
    const html = "<h1>标题</h1><p>段落 <b>粗</b> 文本</p><script>bad()</script>";
    const txt = try convert(testing.allocator, html, .text);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "标题") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "段落 粗 文本") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "bad()") == null);
    try testing.expect(std.mem.indexOf(u8, txt, "#") == null);
}

test "html→md：注释/doctype/无效实体容错" {
    const html = "<!DOCTYPE html><!-- c --><p>a &unknown; b &#; c</p>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "a &unknown; b &#; c") != null);
}

test "html→md：blockquote 与 hr" {
    const html = "<blockquote><p>引用一</p><p>引用二</p></blockquote><hr><p>后</p>";
    const md = try convert(testing.allocator, html, .markdown);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "> 引用一") != null);
    try testing.expect(std.mem.indexOf(u8, md, "---") != null);
}

test "html→md：空输入与纯文本" {
    const empty = try convert(testing.allocator, "", .markdown);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
    const plain = try convert(testing.allocator, "just text &amp; more", .markdown);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("just text & more", plain);
}
