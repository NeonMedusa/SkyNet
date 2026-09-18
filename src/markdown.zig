const std = @import("std");
const tui = @import("zigtui");
const Allocator = std.mem.Allocator;
const Style = tui.style.Style;
const Buffer = tui.render.Buffer;
const codepointWidth = tui.render.codepointWidth;
const stringWidth = tui.render.stringWidth;

pub const Run = struct {
    text: []const u8,
    style: Style,
};

pub const LineKind = enum { normal, rule, table };

/// 表格单元格：一组带样式的 run（文本指向消息内容，不拥有）
const Cell = struct { runs: []Run };

/// 解析中间结果：单元格内容与显示宽度
const CellView = struct { runs: []Run, width: usize };

/// 表格中的一行：或为分隔线，或为一组单元格
const TableRowSpec = struct {
    cells: []Cell = &.{},
    separator: bool = false,
};

/// 解析后的表格结构。列宽与单元格换行在绘制时按可用宽度计算，
/// 因此终端缩放后仍能正确重排（无需重新解析）。
const Table = struct {
    ncols: usize,
    /// 每列的“自然宽度”（各单元格内容显示宽度的最大值，至少 1）
    natural: []usize,
    rows: []TableRowSpec,
};

pub const Line = struct {
    kind: LineKind = .normal,
    runs: []Run = &.{},
    /// 渲染时自生成的文本（如表格边框），随 Line 一并释放
    owned_text: ?[]u8 = null,
    /// 整行填充的背景样式（代码块用，形成完整矩形底色）
    fill_bg: ?Style = null,
    /// 表格行：整张表作为一条 Line 承载，绘制时按宽度重排
    table: ?*Table = null,
};

/// 各部件的显示样式（可覆盖）
pub const Styles = struct {
    base: Style = .{ .fg = .white },
    heading1: Style = .{ .fg = .light_yellow, .modifier = .{ .bold = true } },
    heading2: Style = .{ .fg = .light_cyan, .modifier = .{ .bold = true } },
    heading3: Style = .{ .fg = .light_blue, .modifier = .{ .bold = true } },
    code: Style = .{ .fg = .light_white, .bg = .{ .rgb = .{ .r = 20, .g = 20, .b = 20 } } },
    inline_code: Style = .{ .fg = .light_yellow },
    bullet: Style = .{ .fg = .cyan },
    quote: Style = .{ .fg = .dark_gray },
    rule: Style = .{ .fg = .dark_gray },
    table_border: Style = .{ .fg = .dark_gray },
    bold: Style = .{ .modifier = .{ .bold = true } },
    italic: Style = .{ .modifier = .{ .italic = true } },
    link: Style = .{ .fg = .light_cyan, .modifier = .{ .underlined = true } },
};

pub const default_styles = Styles{};

/// 解析为渲染行（runs 中的文本切片指向 content，content 须保持有效）
pub fn parse(allocator: Allocator, content: []const u8, styles: Styles) ![]Line {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var items: std.ArrayListUnmanaged(Line) = .{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (items.items) |line| {
            if (line.runs.len > 0) allocator.free(line.runs);
            if (line.owned_text) |text| allocator.free(text);
            if (line.table) |table| freeTable(allocator, table);
        }
        items.deinit(allocator);
    }

    const base = styles.base;
    var in_code = false;
    var pos: usize = 0;

    while (readLine(content, &pos)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");

        // 代码块围栏
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code = !in_code;
            continue;
        }
        if (in_code) {
            try appendRuns(allocator, &items, &.{.{ .text = raw, .style = styles.code }});
            items.items[items.items.len - 1].fill_bg = styles.code;
            continue;
        }

        // 空行
        if (trimmed.len == 0) {
            try items.append(allocator, .{});
            continue;
        }

        // 分隔线
        if (isRule(trimmed)) {
            try items.append(allocator, .{ .kind = .rule });
            continue;
        }

        // 标题
        if (heading(trimmed)) |h| {
            const style = switch (h.level) {
                1 => styles.heading1,
                2 => styles.heading2,
                else => styles.heading3,
            };
            try appendInline(allocator, &items, h.text, style, styles);
            continue;
        }

        // 引用
        if (trimmed[0] == '>') {
            var rest = trimmed[1..];
            rest = std.mem.trimStart(u8, rest, " ");
            var runs: std.ArrayListUnmanaged(Run) = .{ .items = &.{}, .capacity = 0 };
            try runs.append(arena, .{ .text = "│ ", .style = styles.quote });
            try parseInline(arena, &runs, rest, base, styles);
            try appendOwnedRuns(allocator, &items, try runs.toOwnedSlice(arena));
            continue;
        }

        // 列表
        if (listMarker(trimmed)) |lm| {
            const indent = raw[0 .. raw.len - trimmed.len];
            var runs: std.ArrayListUnmanaged(Run) = .{ .items = &.{}, .capacity = 0 };
            if (indent.len > 0) {
                try runs.append(arena, .{ .text = indent, .style = base });
            }
            try runs.append(arena, .{ .text = lm.marker, .style = styles.bullet });
            try parseInline(arena, &runs, lm.text, base, styles);
            try appendOwnedRuns(allocator, &items, try runs.toOwnedSlice(arena));
            continue;
        }

        // 表格（以 | 开头且至少两个 |）
        if (trimmed[0] == '|' and countChar(trimmed, '|') >= 2) {
            var rows: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 };
            try rows.append(arena, raw);
            while (true) {
                const save = pos;
                const next = readLine(content, &pos) orelse break;
                const nt = std.mem.trim(u8, next, " \t\r");
                if (nt.len > 0 and nt[0] == '|' and countChar(nt, '|') >= 2) {
                    try rows.append(arena, next);
                } else {
                    pos = save;
                    break;
                }
            }
            try renderTable(allocator, &items, arena, rows.items, styles);
            continue;
        }

        // 普通段落行（保留缩进）
        try appendInline(allocator, &items, raw, base, styles);
    }

    return try items.toOwnedSlice(allocator);
}

pub fn free(allocator: Allocator, lines: []Line) void {
    for (lines) |line| {
        if (line.runs.len > 0) allocator.free(line.runs);
        if (line.owned_text) |text| allocator.free(text);
        if (line.table) |table| freeTable(allocator, table);
    }
    allocator.free(lines);
}

fn freeTable(allocator: Allocator, table: *Table) void {
    for (table.rows) |row| freeCells(allocator, row.cells);
    if (table.rows.len > 0) allocator.free(table.rows);
    if (table.natural.len > 0) allocator.free(table.natural);
    allocator.destroy(table);
}

/// 该行按宽度换行后占用的行数
pub fn rowCount(line: *const Line, width: usize) usize {
    if (line.kind == .rule) return 1;
    if (line.kind == .table) {
        const table = line.table orelse return 0;
        if (width == 0) return 1;
        return tableHeight(table, width);
    }
    if (width == 0) return 1;
    var rows: usize = 1;
    var col: usize = 0;
    for (line.runs) |run| {
        var i: usize = 0;
        while (i < run.text.len) {
            const dec = decodeAt(run.text, i);
            const w: usize = codepointWidth(dec.cp);
            if (w > 0 and col + w > width and col > 0) {
                rows += 1;
                col = 0;
            }
            col += w;
            i += dec.len;
        }
    }
    return rows;
}

/// 绘制该行的第 target_row 个可视行（0 起）
pub fn drawRow(buf: *Buffer, x0: u16, y: u16, line: *const Line, width: usize, target_row: usize, styles: Styles) void {
    if (width == 0) return;

    if (line.kind == .rule) {
        if (target_row != 0) return;
        var j: usize = 0;
        while (j < width) : (j += 1) {
            buf.setChar(x0 +| @as(u16, @intCast(@min(j, 0xFFFF))), y, '─', styles.rule);
        }
        return;
    }

    if (line.kind == .table) {
        if (line.table) |table| drawTable(buf, x0, y, table, width, target_row, styles);
        return;
    }

    var row: usize = 0;
    var col: usize = 0;
    var x: u16 = x0;
    for (line.runs) |run| {
        var i: usize = 0;
        while (i < run.text.len) {
            const dec = decodeAt(run.text, i);
            const w: usize = codepointWidth(dec.cp);
            if (w > 0 and col + w > width and col > 0) {
                row += 1;
                col = 0;
                x = x0;
            }
            if (row == target_row and w > 0) {
                buf.setChar(x, y, dec.cp, run.style);
                x +|= @intCast(w);
            }
            col += w;
            i += dec.len;
        }
    }

    // 整行背景填充（代码块形成完整矩形）
    if (line.fill_bg) |fill_style| {
        const end_x = x0 +| @as(u16, @intCast(@min(width, 0xFFFF)));
        while (x < end_x) : (x += 1) {
            buf.setChar(x, y, ' ', fill_style);
        }
    }
}

/// 可视行内的文本片段（用于文本选择映射）
pub const Segment = struct {
    /// 片段文本（指向原内容）
    text: []const u8,
    /// 屏幕列偏移（相对行首）
    x: usize,
    /// 显示宽度
    width: usize,
};

/// 枚举第 target_row 个可视行内的片段；返回写入 out 的数量
pub fn rowSegments(line: *const Line, width: usize, target_row: usize, out: []Segment) usize {
    if (line.kind == .table) {
        const table = line.table orelse return 0;
        if (width == 0) return 0;
        return tableSegments(table, width, target_row, out);
    }
    if (line.kind == .rule or width == 0) return 0;
    var count: usize = 0;
    var row: usize = 0;
    var col: usize = 0;

    for (line.runs) |run| {
        if (row > target_row) break;
        var i: usize = 0;
        var seg_start: ?usize = null;
        var seg_col: usize = 0;
        while (i < run.text.len) {
            const dec = decodeAt(run.text, i);
            const w: usize = codepointWidth(dec.cp);
            if (w > 0 and col + w > width and col > 0) {
                // 软换行：结束当前片段
                if (seg_start) |s| {
                    if (row == target_row and count < out.len) {
                        out[count] = .{ .text = run.text[s..i], .x = seg_col, .width = col - seg_col };
                        count += 1;
                    }
                    seg_start = null;
                }
                row += 1;
                col = 0;
                if (row > target_row) return count;
            }
            if (row == target_row and seg_start == null) {
                seg_start = i;
                seg_col = col;
            }
            col += w;
            i += dec.len;
        }
        if (seg_start) |s| {
            if (row == target_row and count < out.len) {
                out[count] = .{ .text = run.text[s..run.text.len], .x = seg_col, .width = col - seg_col };
                count += 1;
            }
        }
    }
    return count;
}

const Decoded = struct { cp: u21, len: usize };

fn decodeAt(text: []const u8, i: usize) Decoded {
    var len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    if (i + len > text.len) len = 1;
    const cp: u21 = if (len == 1)
        text[i]
    else
        std.unicode.utf8Decode(text[i .. i + len]) catch 0xFFFD;
    return .{ .cp = cp, .len = len };
}

fn readLine(content: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= content.len) return null;
    const start = pos.*;
    const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
    pos.* = if (end < content.len) end + 1 else content.len;
    return content[start..end];
}

fn countChar(s: []const u8, c: u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) n += 1;
    }
    return n;
}

fn isRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const c = trimmed[0];
    if (c != '-' and c != '*' and c != '_') return false;
    for (trimmed) |ch| {
        if (ch != c and ch != ' ') return false;
    }
    return true;
}

const Heading = struct { level: usize, text: []const u8 };

fn heading(trimmed: []const u8) ?Heading {
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < trimmed.len and trimmed[n] != ' ') return null;
    const text = std.mem.trimStart(u8, trimmed[n..], " ");
    return .{ .level = n, .text = text };
}

const ListMarker = struct { marker: []const u8, text: []const u8 };

fn listMarker(trimmed: []const u8) ?ListMarker {
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        return .{ .marker = "• ", .text = trimmed[2..] };
    }
    // 有序列表：数字 + ". "
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') i += 1;
    if (i > 0 and i + 1 < trimmed.len and trimmed[i] == '.' and trimmed[i + 1] == ' ') {
        return .{ .marker = trimmed[0 .. i + 2], .text = trimmed[i + 2 ..] };
    }
    return null;
}

fn appendRuns(allocator: Allocator, items: *std.ArrayListUnmanaged(Line), runs: []const Run) !void {
    const owned = try allocator.dupe(Run, runs);
    items.append(allocator, .{ .runs = owned }) catch |err| {
        allocator.free(owned);
        return err;
    };
}

fn appendOwnedRuns(allocator: Allocator, items: *std.ArrayListUnmanaged(Line), runs: []Run) !void {
    const owned = try allocator.dupe(Run, runs);
    items.append(allocator, .{ .runs = owned }) catch |err| {
        allocator.free(owned);
        return err;
    };
}

fn appendInline(allocator: Allocator, items: *std.ArrayListUnmanaged(Line), text: []const u8, base: Style, styles: Styles) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var runs: std.ArrayListUnmanaged(Run) = .{ .items = &.{}, .capacity = 0 };
    try parseInline(arena_state.allocator(), &runs, text, base, styles);
    if (runs.items.len == 0) {
        try items.append(allocator, .{});
        return;
    }
    try appendOwnedRuns(allocator, items, runs.items);
}

const inline_markers = struct {
    const bold = "**";
};

fn parseInline(allocator: Allocator, runs: *std.ArrayListUnmanaged(Run), text: []const u8, base: Style, styles: Styles) !void {
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // 行内代码
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                if (end > i + 1) {
                    try addPlain(allocator, runs, text[plain_start..i], base);
                    try runs.append(allocator, .{ .text = text[i + 1 .. end], .style = base.merge(styles.inline_code) });
                    i = end + 1;
                    plain_start = i;
                    continue;
                }
            }
        }

        // 粗体
        if ((c == '*' or c == '_') and i + 1 < text.len and text[i + 1] == c) {
            const prev_ok = c != '_' or i == 0 or !isWordChar(text[i - 1]);
            const marker = text[i .. i + 2];
            if (prev_ok) {
                if (std.mem.indexOfPos(u8, text, i + 2, marker)) |end| {
                    const next_ok = c != '_' or end + 2 >= text.len or !isWordChar(text[end + 2]);
                    if (end > i + 2 and next_ok) {
                        try addPlain(allocator, runs, text[plain_start..i], base);
                        try runs.append(allocator, .{ .text = text[i + 2 .. end], .style = base.merge(styles.bold) });
                        i = end + 2;
                        plain_start = i;
                        continue;
                    }
                }
            }
        }

        // 斜体
        if (c == '*' or c == '_') {
            const prev_ok = c != '_' or i == 0 or !isWordChar(text[i - 1]);
            if (prev_ok) {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, c)) |end| {
                    const next_ok = c != '_' or end + 1 >= text.len or !isWordChar(text[end + 1]);
                    if (end > i + 1 and next_ok) {
                        try addPlain(allocator, runs, text[plain_start..i], base);
                        try runs.append(allocator, .{ .text = text[i + 1 .. end], .style = base.merge(styles.italic) });
                        i = end + 1;
                        plain_start = i;
                        continue;
                    }
                }
            }
        }

        // 链接 [文本](url)
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |mid| {
                if (mid + 1 < text.len and text[mid + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, mid + 2, ')')) |end| {
                        try addPlain(allocator, runs, text[plain_start..i], base);
                        try runs.append(allocator, .{ .text = text[i + 1 .. mid], .style = base.merge(styles.link) });
                        try runs.append(allocator, .{ .text = text[mid + 1 .. end + 1], .style = styles.quote });
                        i = end + 1;
                        plain_start = i;
                        continue;
                    }
                }
            }
        }

        i += 1;
    }
    try addPlain(allocator, runs, text[plain_start..], base);
}

fn addPlain(allocator: Allocator, runs: *std.ArrayListUnmanaged(Run), text: []const u8, style: Style) !void {
    if (text.len == 0) return;
    try runs.append(allocator, .{ .text = text, .style = style });
}

fn isWordChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ── 表格渲染 ──

/// 单张表最多渲染的列数（异常输入的保护上限）
const max_table_cols = 64;

fn renderTable(
    allocator: Allocator,
    items: *std.ArrayListUnmanaged(Line),
    arena: Allocator,
    rows: []const []const u8,
    styles: Styles,
) !void {
    // 逐行解析单元格（中间结果放在 arena，最终复制到 allocator）
    var view_rows: std.ArrayListUnmanaged([]CellView) = .{ .items = &.{}, .capacity = 0 };
    var ncols: usize = 0;
    for (rows) |raw| {
        var s = std.mem.trim(u8, raw, " \t");
        if (s.len > 0 and s[0] == '|') s = s[1..];
        if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];

        var cells: std.ArrayListUnmanaged(CellView) = .{ .items = &.{}, .capacity = 0 };
        var it = std.mem.splitScalar(u8, s, '|');
        while (it.next()) |c| {
            const cell_text = std.mem.trim(u8, c, " \t");
            var runs: std.ArrayListUnmanaged(Run) = .{ .items = &.{}, .capacity = 0 };
            try parseInline(arena, &runs, cell_text, styles.base, styles);
            var w: usize = 0;
            for (runs.items) |r| w += stringWidth(r.text);
            try cells.append(arena, .{ .runs = runs.items, .width = w });
        }
        ncols = @max(ncols, @min(cells.items.len, max_table_cols));
        try view_rows.append(arena, cells.items[0..@min(cells.items.len, max_table_cols)]);
    }
    if (ncols == 0) return;

    const has_sep = view_rows.items.len > 1 and isSeparatorRow(view_rows.items[1]);
    const table = try buildTable(allocator, view_rows.items, ncols, has_sep, styles);
    errdefer freeTable(allocator, table);
    try items.append(allocator, .{ .kind = .table, .runs = &.{}, .table = table });
}

fn freeCells(allocator: Allocator, cells: []Cell) void {
    for (cells) |cell| {
        if (cell.runs.len > 0) allocator.free(cell.runs);
    }
    if (cells.len > 0) allocator.free(cells);
}

/// 由解析视图构建出持久的 Table（所有权：natural / rows / 各 cells / 各 runs 均由 allocator 持有）
fn buildTable(
    allocator: Allocator,
    view_rows: []const []CellView,
    ncols: usize,
    has_sep: bool,
    styles: Styles,
) !*Table {
    // 每列自然宽度（内容行）
    const natural = try allocator.alloc(usize, ncols);
    errdefer allocator.free(natural);
    @memset(natural, 1);
    for (view_rows) |cells| {
        if (isSeparatorRow(cells)) continue;
        for (cells, 0..) |cell, ci| {
            if (ci < ncols) natural[ci] = @max(natural[ci], cell.width);
        }
    }

    var table_rows: std.ArrayListUnmanaged(TableRowSpec) = .{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (table_rows.items) |row| freeCells(allocator, row.cells);
        table_rows.deinit(allocator);
    }
    for (view_rows, 0..) |cells, ri| {
        if (isSeparatorRow(cells)) {
            try table_rows.append(allocator, .{ .separator = true });
            continue;
        }
        // 行间横线：内容行之间都插入一条分隔线（源里若已有分隔线则不重复）
        if (table_rows.items.len > 0 and !table_rows.items[table_rows.items.len - 1].separator) {
            try table_rows.append(allocator, .{ .separator = true });
        }
        const is_header = ri == 0 and has_sep;
        const out_cells = try allocator.alloc(Cell, ncols);
        errdefer allocator.free(out_cells);
        for (0..ncols) |ci| {
            if (ci < cells.len and cells[ci].runs.len > 0) {
                const runs = try allocator.dupe(Run, cells[ci].runs);
                if (is_header) {
                    for (runs) |*r| r.style = r.style.merge(styles.bold);
                }
                out_cells[ci] = .{ .runs = runs };
            } else {
                out_cells[ci] = .{ .runs = &.{} };
            }
        }
        try table_rows.append(allocator, .{ .cells = out_cells });
    }

    const table = try allocator.create(Table);
    errdefer allocator.destroy(table);
    // toOwnedSlice 得到精确长度的切片，避免 free 时 len/capacity 不匹配
    table.* = .{ .ncols = ncols, .natural = natural, .rows = try table_rows.toOwnedSlice(allocator) };
    return table;
}

fn isSeparatorRow(cells: []const CellView) bool {
    if (cells.len == 0) return false;
    var has_dash = false;
    for (cells) |cell| {
        if (cell.runs.len == 0) return false;
        for (cell.runs) |r| {
            for (r.text) |ch| {
                if (ch == '-') {
                    has_dash = true;
                } else if (ch != ':' and ch != ' ') {
                    return false;
                }
            }
        }
    }
    return has_dash;
}

// ── 表格绘制（按可用宽度重排，单元格内换行）──

/// 计算适配到 width 的列内容宽度；返回是否能完整容纳。
/// 不能容纳时把各列宽度置 1，绘制时按缓冲边界裁切。
fn tableColWidths(table: *const Table, width: usize, out: []usize) bool {
    const ncols = table.ncols;
    if (ncols == 0) return true;
    // 每列开销："│ " + " " = 3，外加末尾一个 "│"
    const overhead = 3 * ncols + 1;
    if (width < overhead + ncols) {
        for (out[0..ncols]) |*w| w.* = 1;
        return false;
    }
    const avail = width - overhead;
    var max_natural: usize = 1;
    for (table.natural) |x| max_natural = @max(max_natural, x);

    // 二分最大统一上限 cap：sum(min(natural_i, cap)) <= avail
    var lo: usize = 1;
    var hi: usize = max_natural;
    var best: usize = 1;
    while (lo <= hi) {
        const mid = lo + (hi - lo) / 2;
        var sum: usize = 0;
        for (table.natural) |nat| sum += @min(nat, mid);
        if (sum <= avail) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    for (table.natural, 0..) |nat, i| out[i] = @min(nat, best);
    return true;
}

// ── 单元格折行（按词换行）──

const CellCursor = struct { run: usize = 0, byte: usize = 0 };

/// 一行内容在“单元格 run 序列”中的游标区间 [start, end)
const CellLine = struct { start: CellCursor, end: CellCursor };

/// 单元格按词换行的行迭代器。
/// 规则：优先在空格处断行（行尾空格丢弃、下一行行首空格跳过）；
/// 单个词长于列宽时退化为按字符硬断行（与旧行为一致）。
const CellWrapIter = struct {
    runs: []const Run,
    width: usize,
    cur: CellCursor = .{},

    /// 取下一物理行；无更多内容时返回 null
    fn next(self: *CellWrapIter) ?CellLine {
        // 跳过行首空格与空 run
        while (self.cur.run < self.runs.len) {
            const run = self.runs[self.cur.run];
            if (self.cur.byte >= run.text.len) {
                self.cur.run += 1;
                self.cur.byte = 0;
                continue;
            }
            if (decodeAt(run.text, self.cur.byte).cp == ' ') {
                self.cur.byte += 1;
                continue;
            }
            break;
        }
        if (self.cur.run >= self.runs.len) return null;

        const start = self.cur;
        var cur = start;
        var col: usize = 0;
        var content_end = start;
        var break_content_end: ?CellCursor = null; // 词断行：内容末尾（空格处）
        var break_next: ?CellCursor = null; // 词断行：下一行起点（空格之后）
        var overflowed = false;

        while (true) {
            while (cur.run < self.runs.len and cur.byte >= self.runs[cur.run].text.len) {
                cur.run += 1;
                cur.byte = 0;
            }
            if (cur.run >= self.runs.len) break;
            const dec = decodeAt(self.runs[cur.run].text, cur.byte);
            const cw: usize = codepointWidth(dec.cp);
            const after = CellCursor{ .run = cur.run, .byte = cur.byte + dec.len };
            // 空格即断行点：即使它本行放不下，也应在它前面断行（此时行宽已用满）
            if (dec.cp == ' ') {
                break_content_end = cur;
                break_next = after;
            }
            if (cw > 0 and col + cw > self.width and col > 0) {
                overflowed = true;
                break;
            }
            content_end = after;
            col += cw;
            cur = after;
        }

        if (overflowed and break_next != null) {
            self.cur = break_next.?;
            return .{ .start = start, .end = break_content_end.? };
        }
        self.cur = cur;
        return .{ .start = start, .end = content_end };
    }
};

/// 单元格在给定内容宽度下折成的行数
fn cellWrapRows(runs: []const Run, w: usize) usize {
    if (w == 0) return 1;
    var it = CellWrapIter{ .runs = runs, .width = w };
    var rows: usize = 0;
    while (it.next() != null) rows += 1;
    return @max(rows, 1);
}

fn rowSpecHeight(spec: TableRowSpec, widths: []const usize, ncols: usize) usize {
    if (spec.separator) return 1;
    var h: usize = 1;
    for (0..ncols) |ci| {
        if (ci < spec.cells.len) h = @max(h, cellWrapRows(spec.cells[ci].runs, widths[ci]));
    }
    return h;
}

fn tableHeight(table: *const Table, width: usize) usize {
    var widths: [max_table_cols]usize = undefined;
    _ = tableColWidths(table, width, widths[0..table.ncols]);
    // 上边框 + 各行 + 下边框
    var total: usize = 2;
    for (table.rows) |spec| total += rowSpecHeight(spec, widths[0..table.ncols], table.ncols);
    return total;
}

fn drawTable(buf: *Buffer, x0: u16, y: u16, table: *const Table, width: usize, target_row: usize, styles: Styles) void {
    var widths: [max_table_cols]usize = undefined;
    _ = tableColWidths(table, width, widths[0..table.ncols]);
    const ws = widths[0..table.ncols];

    if (target_row == 0) {
        drawTableBorder(buf, x0, y, ws, '┌', '┬', '┐', styles);
        return;
    }
    var row_index: usize = 1;
    for (table.rows) |spec| {
        const h = rowSpecHeight(spec, ws, table.ncols);
        if (target_row < row_index + h) {
            const sub = target_row - row_index;
            if (spec.separator) {
                drawTableBorder(buf, x0, y, ws, '├', '┼', '┤', styles);
            } else {
                drawTableContentRow(buf, x0, y, spec, ws, table.ncols, sub, styles);
            }
            return;
        }
        row_index += h;
    }
    // 下边框
    drawTableBorder(buf, x0, y, ws, '└', '┴', '┘', styles);
}

fn drawTableBorder(buf: *Buffer, x0: u16, y: u16, widths: []const usize, left: u21, mid: u21, right: u21, styles: Styles) void {
    var x: usize = x0;
    const style = styles.table_border;
    buf.setChar(clampX(x), y, left, style);
    x += 1;
    for (widths, 0..) |w, ci| {
        if (ci > 0) {
            buf.setChar(clampX(x), y, mid, style);
            x += 1;
        }
        var j: usize = 0;
        while (j < w + 2) : (j += 1) {
            buf.setChar(clampX(x), y, '─', style);
            x += 1;
        }
    }
    buf.setChar(clampX(x), y, right, style);
}

fn drawTableContentRow(
    buf: *Buffer,
    x0: u16,
    y: u16,
    spec: TableRowSpec,
    widths: []const usize,
    ncols: usize,
    sub_row: usize,
    styles: Styles,
) void {
    var x: usize = x0;
    for (0..ncols) |ci| {
        const w = widths[ci];
        buf.setChar(clampX(x), y, '│', styles.table_border);
        x += 1;
        buf.setChar(clampX(x), y, ' ', styles.base);
        x += 1;
        if (ci < spec.cells.len) {
            drawCellChunk(buf, x, y, spec.cells[ci].runs, w, sub_row, styles);
        } else {
            var j: usize = 0;
            while (j < w) : (j += 1) {
                buf.setChar(clampX(x + j), y, ' ', styles.base);
            }
        }
        x += w;
        buf.setChar(clampX(x), y, ' ', styles.base);
        x += 1;
    }
    buf.setChar(clampX(x), y, '│', styles.table_border);
}

/// 绘制某单元格在 sub_row 这一物理行上的内容（左对齐，右侧补空格到 w 列）
fn drawCellChunk(buf: *Buffer, x_start: usize, y: u16, runs: []const Run, w: usize, sub_row: usize, styles: Styles) void {
    var it = CellWrapIter{ .runs = runs, .width = w };
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx == sub_row) {
            drawCellLine(buf, x_start, y, runs, line, w, styles);
            return;
        }
    }
    fillSpaces(buf, x_start, y, x_start + w, styles.base);
}

/// 绘制单元格某一行（游标区间 [line.start, line.end)），逐 run 绘制以获得正确样式
fn drawCellLine(buf: *Buffer, x_start: usize, y: u16, runs: []const Run, line: CellLine, w: usize, styles: Styles) void {
    var x = x_start;
    var r = line.start.run;
    var b = line.start.byte;
    while (r <= line.end.run and r < runs.len) {
        const run = runs[r];
        const seg_end = if (r == line.end.run) line.end.byte else run.text.len;
        var i = b;
        while (i < seg_end) {
            const dec = decodeAt(run.text, i);
            const cw: usize = codepointWidth(dec.cp);
            if (cw > 0) {
                buf.setChar(clampX(x), y, dec.cp, run.style);
                x += cw;
            }
            i += dec.len;
        }
        if (r == line.end.run) break;
        r += 1;
        b = 0;
    }
    fillSpaces(buf, x, y, x_start + w, styles.base);
}

fn fillSpaces(buf: *Buffer, from: usize, y: u16, to: usize, style: Style) void {
    var x = from;
    while (x < to) : (x += 1) {
        buf.setChar(clampX(x), y, ' ', style);
    }
}

fn clampX(x: usize) u16 {
    return @intCast(@min(x, 0xFFFF));
}

/// 非内容片段（边框/单元格填充）的占位文本：其指针不在消息内容内，
/// recordMdRow 会据此把它折叠进前一个内容片段的宽度。
const table_gap = "│ ";

fn tableSegments(table: *const Table, width: usize, target_row: usize, out: []Segment) usize {
    var widths: [max_table_cols]usize = undefined;
    _ = tableColWidths(table, width, widths[0..table.ncols]);

    if (target_row == 0) return 0;
    var row_index: usize = 1;
    for (table.rows) |spec| {
        const h = rowSpecHeight(spec, widths[0..table.ncols], table.ncols);
        if (target_row < row_index + h) {
            if (spec.separator) return 0;
            return tableRowSegments(table, spec, widths[0..table.ncols], target_row - row_index, out);
        }
        row_index += h;
    }
    return 0;
}

fn tableRowSegments(table: *const Table, spec: TableRowSpec, widths: []const usize, sub_row: usize, out: []Segment) usize {
    var count: usize = 0;
    var ci: usize = 0;
    while (ci < table.ncols) : (ci += 1) {
        const w = widths[ci];
        const cstart = 2 + (if (ci == 0) 0 else blk: {
            // content_start(ci) = 2 + sum_{j<ci}(w_j + 3)
            var s: usize = 0;
            for (widths[0..ci]) |wj| s += wj + 3;
            break :blk s;
        });
        var actual_end = cstart;
        if (ci < spec.cells.len) {
            const n = cellSegments(spec.cells[ci].runs, w, sub_row, cstart, out[count..]);
            for (out[count .. count + n]) |s| actual_end = @max(actual_end, s.x + s.width);
            count += n;
        }
        // 该列到下一列内容起点（或表格右边界）之间的边框/填充：折叠进前一内容片段
        const next_start = cstart + w + 3;
        const boundary = if (ci + 1 < table.ncols) next_start else cstart + w + 2;
        if (count > 0 and boundary > actual_end and count < out.len) {
            out[count] = .{ .text = table_gap, .x = actual_end, .width = boundary - actual_end };
            count += 1;
        }
    }
    return count;
}

/// 枚举某单元格在 sub_row 这一物理行上的内容片段（x 为相对行首的列偏移）
fn cellSegments(runs: []const Run, w: usize, sub_row: usize, x_start: usize, out: []Segment) usize {
    var it = CellWrapIter{ .runs = runs, .width = w };
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx == sub_row) return cellLineSegments(runs, line, x_start, out);
    }
    return 0;
}

fn cellLineSegments(runs: []const Run, line: CellLine, x_start: usize, out: []Segment) usize {
    var count: usize = 0;
    var col: usize = 0;
    var r = line.start.run;
    var b = line.start.byte;
    while (r <= line.end.run and r < runs.len) {
        const run = runs[r];
        const seg_end = if (r == line.end.run) line.end.byte else run.text.len;
        if (seg_end > b) {
            if (count >= out.len) break;
            const text = run.text[b..seg_end];
            const sw = stringWidth(text);
            out[count] = .{ .text = text, .x = x_start + col, .width = sw };
            count += 1;
            col += sw;
        }
        if (r == line.end.run) break;
        r += 1;
        b = 0;
    }
    return count;
}

// ── 测试 ──

const testing = std.testing;

/// 读取缓冲区某一行的文本（跳过宽字符的续列，去除行尾空格）
fn bufferRowText(allocator: Allocator, buf: *Buffer, y: u16, width: u16) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    var x: u16 = 0;
    while (x < width) {
        const cell = buf.get(x, y) orelse break;
        if (cell.width == 0) {
            x += 1;
            continue;
        }
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.char, &tmp) catch 0;
        try out.appendSlice(allocator, tmp[0..@as(usize, n)]);
        x += cell.width;
    }
    // 去除行尾空格
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        out.items.len -= 1;
    }
    return out.toOwnedSlice(allocator);
}

fn drawTableRows(allocator: Allocator, line: *const Line, width: u16) !struct { buf: Buffer, rows: usize } {
    const rows = rowCount(line, width);
    var buf = try Buffer.init(allocator, width, @intCast(@max(rows, 1)));
    for (0..rows) |r| drawRow(&buf, 0, @intCast(r), line, width, r, default_styles);
    return .{ .buf = buf, .rows = rows };
}

fn checkTableRow(allocator: Allocator, buf: *Buffer, y: u16, width: u16, expected: []const u8) !void {
    const text = try bufferRowText(allocator, buf, y, width);
    defer allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "标题与粗体" {
    const content = "# Title\n**bold** text";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("Title", lines[0].runs[0].text);
    try testing.expect(lines[0].runs[0].style.modifier.bold);
    try testing.expectEqualStrings("bold", lines[1].runs[0].text);
    try testing.expect(lines[1].runs[0].style.modifier.bold);
    try testing.expectEqualStrings(" text", lines[1].runs[1].text);
}

test "行内代码与中文" {
    const content = "使用 `zig build` 编译";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    try testing.expectEqualStrings("使用 ", lines[0].runs[0].text);
    try testing.expectEqualStrings("zig build", lines[0].runs[1].text);
    try testing.expectEqualStrings(" 编译", lines[0].runs[2].text);
}

test "代码块保留原文并去掉围栏" {
    const content = "```zig\nconst x = 1; // 注释\n```\n普通行";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("const x = 1; // 注释", lines[0].runs[0].text);
    try testing.expect(lines[0].runs[0].style.bg != null);
    // 代码行带整行背景填充
    try testing.expect(lines[0].fill_bg != null);
    try testing.expectEqualStrings("普通行", lines[1].runs[0].text);
    try testing.expect(lines[1].fill_bg == null);
}

test "列表与分隔线" {
    const content = "- 第一项\n1. 有序项\n---";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("• ", lines[0].runs[0].text);
    try testing.expectEqualStrings("第一项", lines[0].runs[1].text);
    try testing.expectEqualStrings("1. ", lines[1].runs[0].text);
    try testing.expectEqual(LineKind.rule, lines[2].kind);
}

test "snake_case 不应被斜体化" {
    const content = "foo_bar_baz 变量";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 1), lines[0].runs.len);
    try testing.expectEqualStrings("foo_bar_baz 变量", lines[0].runs[0].text);
}

test "未闭合的标记按字面显示" {
    const content = "**未闭合的粗体";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 1), lines[0].runs.len);
    try testing.expectEqualStrings("**未闭合的粗体", lines[0].runs[0].text);
}

test "表格渲染为边框线" {
    const content = "| 方法 | 复杂度 |\n|---|---|\n| 迭代 | O(n) |";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    // 整张表作为一条 Line
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(LineKind.table, lines[0].kind);

    const width: u16 = 40;
    var drawn = try drawTableRows(testing.allocator, &lines[0], width);
    defer drawn.buf.deinit();
    try testing.expectEqual(@as(usize, 5), drawn.rows);

    try checkTableRow(testing.allocator, &drawn.buf, 0, width, "┌──────┬────────┐");
    try checkTableRow(testing.allocator, &drawn.buf, 1, width, "│ 方法 │ 复杂度 │");
    try checkTableRow(testing.allocator, &drawn.buf, 2, width, "├──────┼────────┤");
    try checkTableRow(testing.allocator, &drawn.buf, 3, width, "│ 迭代 │ O(n)   │");
    try checkTableRow(testing.allocator, &drawn.buf, 4, width, "└──────┴────────┘");
}

test "表格相邻数据行之间画横线" {
    const content = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    const width: u16 = 40;
    var drawn = try drawTableRows(testing.allocator, &lines[0], width);
    defer drawn.buf.deinit();

    // 上边框 + 表头 + 分隔 + 数据 + 分隔 + 数据 + 下边框 = 7
    try testing.expectEqual(@as(usize, 7), drawn.rows);
    try checkTableRow(testing.allocator, &drawn.buf, 0, width, "┌───┬───┐");
    try checkTableRow(testing.allocator, &drawn.buf, 1, width, "│ a │ b │");
    try checkTableRow(testing.allocator, &drawn.buf, 2, width, "├───┼───┤");
    try checkTableRow(testing.allocator, &drawn.buf, 3, width, "│ 1 │ 2 │");
    try checkTableRow(testing.allocator, &drawn.buf, 4, width, "├───┼───┤");
    try checkTableRow(testing.allocator, &drawn.buf, 5, width, "│ 3 │ 4 │");
    try checkTableRow(testing.allocator, &drawn.buf, 6, width, "└───┴───┘");
}

test "表格超宽时列内换行且边框保持对齐" {
    const content = "| 名称 | 说明 |\n|---|---|\n| alpha | 一二三四五六七八 |";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    // 窄宽度：第 2 列内容需换行
    const width: u16 = 20;
    var drawn = try drawTableRows(testing.allocator, &lines[0], width);
    defer drawn.buf.deinit();

    // 上边框/表头/中分隔/数据(2 行)/下边框 = 6
    try testing.expectEqual(@as(usize, 6), drawn.rows);
    try testing.expectEqual(@as(usize, 6), rowCount(&lines[0], width));

    // 每一物理行首尾都是制表符（U+2500 区块 → UTF-8 前缀 E2 94），
    // 且显示宽度一致（即左边框对齐），并且不超过可用宽度
    var first_width: ?usize = null;
    for (0..drawn.rows) |r| {
        const t = try bufferRowText(testing.allocator, &drawn.buf, @intCast(r), width);
        defer testing.allocator.free(t);
        try testing.expect(t.len >= 3 and t[0] == 0xE2 and t[1] == 0x94);
        try testing.expect(t.len >= 3 and t[t.len - 3] == 0xE2 and t[t.len - 2] == 0x94);
        const w = stringWidth(t);
        try testing.expect(w <= width);
        if (first_width) |fw| {
            try testing.expectEqual(fw, w);
        } else {
            first_width = w;
        }
    }
}

test "表格单元格按词换行（不拆单词）" {
    const content = "| h |\n|---|\n| one two three four |";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    // 宽度 12 → 单列内容宽 8："one two three four" 按词换行
    const width: u16 = 12;
    var drawn = try drawTableRows(testing.allocator, &lines[0], width);
    defer drawn.buf.deinit();

    // 上边框/表头/分隔/数据×3/下边框 = 7
    try testing.expectEqual(@as(usize, 7), drawn.rows);
    // 断在词间："one two" / "three" / "four"，单词完整不被拆开
    try checkTableRow(testing.allocator, &drawn.buf, 3, width, "│ one two  │");
    try checkTableRow(testing.allocator, &drawn.buf, 4, width, "│ three    │");
    try checkTableRow(testing.allocator, &drawn.buf, 5, width, "│ four     │");
}

test "换行计数按显示宽度" {
    // 每行宽度 4：8 个 ASCII 字符 → 2 行
    const content = "abcdefgh";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 2), rowCount(&lines[0], 4));

    // 中文每字 2 列：4 个汉字宽度 8 → 宽度 4 时 2 行
    const cjk = "中文中文";
    const lines2 = try parse(testing.allocator, cjk, default_styles);
    defer free(testing.allocator, lines2);
    try testing.expectEqual(@as(usize, 2), rowCount(&lines2[0], 4));
}

test "rowSegments: 折行片段与列偏移" {
    const content = "**ab** cd";
    const lines = try parse(testing.allocator, content, default_styles);
    defer free(testing.allocator, lines);

    var segs: [8]Segment = undefined;

    // 宽度 4：第一行为 "ab c"（两个 run 各一段），第二行为 "d"
    const n0 = rowSegments(&lines[0], 4, 0, &segs);
    try testing.expectEqual(@as(usize, 2), n0);
    try testing.expectEqualStrings("ab", segs[0].text);
    try testing.expectEqual(@as(usize, 0), segs[0].x);
    try testing.expectEqual(@as(usize, 2), segs[0].width);
    try testing.expectEqualStrings(" c", segs[1].text);
    try testing.expectEqual(@as(usize, 2), segs[1].x);
    try testing.expectEqual(@as(usize, 2), segs[1].width);

    const n1 = rowSegments(&lines[0], 4, 1, &segs);
    try testing.expectEqual(@as(usize, 1), n1);
    try testing.expectEqualStrings("d", segs[0].text);
    try testing.expectEqual(@as(usize, 0), segs[0].x);

    // 中文宽字符：宽度 2 时每行一个字
    const cjk = "中文";
    const lines2 = try parse(testing.allocator, cjk, default_styles);
    defer free(testing.allocator, lines2);
    const n2 = rowSegments(&lines2[0], 2, 0, &segs);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqualStrings("中", segs[0].text);
    try testing.expectEqual(@as(usize, 2), segs[0].width);
}
