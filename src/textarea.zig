const std = @import("std");
const tui = @import("zigtui");
const Style = tui.style.Style;
const Buffer = tui.render.Buffer;
const Rect = tui.render.Rect;
const codepointWidth = tui.render.codepointWidth;
const Allocator = std.mem.Allocator;

/// 输入框软上限：防止异常超大粘贴耗尽内存（堆上动态缓冲，正常使用远达不到）
pub const max_input_bytes: usize = 8 * 1024 * 1024;

/// 多行文本输入框：堆上动态缓冲，支持换行、按显示宽度自动折行、光标上下移动与视口滚动
pub const TextArea = struct {
    const Self = @This();

    /// 缓冲分配器（默认 page_allocator，实际使用时应设置为应用分配器）
    allocator: Allocator = std.heap.page_allocator,
    buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 },
    /// 字节偏移，始终位于码点边界
    cursor: usize = 0,
    /// 视口顶部所在的可视行（绝对行号）
    view_start: usize = 0,
    /// 光标移动/编辑后，下一帧视口需要跟随光标（手动滚动/点击置位为 false）
    follow_cursor: bool = true,
    /// 光标当前是否可见（闪烁由外部按时间设置）
    blink_on: bool = true,
    /// 选区字节范围 [lo, hi)（由外部设置；null 表示无选区）
    sel_range: ?[2]usize = null,
    /// 光标样式：光标落在选中字符上且闪烁可见时使用（灰底，区别于普通光标的白色）
    cursor_sel_style: Style = .{ .fg = .black, .bg = .dark_gray },
    focused: bool = true,
    /// 是否绘制应用层方块光标。主输入框置 false 改用真实终端光标：
    /// IME 组合串由终端渲染在真实光标处，方块光标会与其重叠，且每次闪烁
    /// 重写该格会让终端连同组合串一起重绘 → 字母闪烁（表单仍用方块光标）
    draw_fake_cursor: bool = true,
    style: Style = .{},
    cursor_style: Style = .{},
    placeholder: []const u8 = "",
    placeholder_style: Style = .{},

    pub const RowCol = struct { row: usize, col: usize };

    /// 释放缓冲（使用应用分配器时必须调用）
    pub fn deinit(self: *Self) void {
        self.buf.deinit(self.allocator);
        self.buf = .{ .items = &.{}, .capacity = 0 };
    }

    pub fn value(self: *const Self) []const u8 {
        return self.buf.items;
    }

    /// 当前文本字节数
    pub fn byteLen(self: *const Self) usize {
        return self.buf.items.len;
    }

    pub fn clear(self: *Self) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.follow_cursor = true;
    }

    pub fn insertCodepoint(self: *Self, cp: u21) void {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch return;
        self.insertBytes(enc[0..n]);
    }

    /// 插入字节（超出软上限时截断，且不切开多字节字符）
    pub fn insertBytes(self: *Self, bytes: []const u8) void {
        _ = self.insertBytesTruncated(bytes);
    }

    /// 同 insertBytes，但返回实际插入的字节数（达到软上限/内存不足时小于 bytes.len）
    pub fn insertBytesTruncated(self: *Self, bytes: []const u8) usize {
        if (bytes.len == 0) return 0;
        self.follow_cursor = true;
        const room = max_input_bytes -| self.buf.items.len;
        if (room == 0) return 0;
        var n = @min(bytes.len, room);
        // 截断点不能落在 UTF-8 连续字节上，否则会插入半个字符
        while (n > 0 and n < bytes.len and (bytes[n] & 0xC0) == 0x80) n -= 1;
        self.buf.insertSlice(self.allocator, self.cursor, bytes[0..n]) catch return 0;
        self.cursor += n;
        return n;
    }

    pub fn deleteBackward(self: *Self) void {
        if (self.cursor == 0) return;
        self.follow_cursor = true;
        const n = self.prevCpLen();
        std.mem.copyForwards(u8, self.buf.items[self.cursor - n .. self.buf.items.len - n], self.buf.items[self.cursor..self.buf.items.len]);
        self.buf.items.len -= n;
        self.cursor -= n;
    }

    pub fn deleteForward(self: *Self) void {
        if (self.cursor >= self.buf.items.len) return;
        self.follow_cursor = true;
        const n = self.nextCpLen();
        std.mem.copyForwards(u8, self.buf.items[self.cursor .. self.buf.items.len - n], self.buf.items[self.cursor + n .. self.buf.items.len]);
        self.buf.items.len -= n;
    }

    /// 删除字节区间 [start, end)（越界自动裁剪），光标落在区间起点
    pub fn deleteRange(self: *Self, start: usize, end: usize) void {
        const lo = @min(start, self.buf.items.len);
        const hi = @min(end, self.buf.items.len);
        if (hi <= lo) return;
        std.mem.copyForwards(u8, self.buf.items[lo .. self.buf.items.len - (hi - lo)], self.buf.items[hi..self.buf.items.len]);
        self.buf.items.len -= (hi - lo);
        self.cursor = lo;
        self.follow_cursor = true;
    }

    pub fn moveCursorLeft(self: *Self) void {
        self.follow_cursor = true;
        if (self.cursor == 0) return;
        self.cursor -= self.prevCpLen();
    }

    pub fn moveCursorRight(self: *Self) void {
        self.follow_cursor = true;
        if (self.cursor >= self.buf.items.len) return;
        self.cursor += self.nextCpLen();
    }

    /// 光标移到文本开头
    pub fn moveCursorHome(self: *Self) void {
        self.follow_cursor = true;
        self.cursor = 0;
    }

    /// 光标移到文本末尾
    pub fn moveCursorEnd(self: *Self) void {
        self.follow_cursor = true;
        self.cursor = self.buf.items.len;
    }

    /// Home：当前逻辑行行首
    pub fn moveCursorLineHome(self: *Self) void {
        self.follow_cursor = true;
        const before = self.buf.items[0..self.cursor];
        if (std.mem.lastIndexOfScalar(u8, before, '\n')) |idx| {
            self.cursor = idx + 1;
        } else {
            self.cursor = 0;
        }
    }

    /// End：当前逻辑行行尾
    pub fn moveCursorLineEnd(self: *Self) void {
        self.follow_cursor = true;
        if (std.mem.indexOfScalarPos(u8, self.buf.items, self.cursor, '\n')) |idx| {
            self.cursor = idx;
        } else {
            self.cursor = self.buf.items.len;
        }
    }

    /// 上/下移动光标（按显示行）；已在首/末行时返回 false
    pub fn moveCursorVert(self: *Self, width: usize, up: bool) bool {
        if (width == 0) return false;
        const rc = self.cursorRowCol(width);
        const target_row = if (up) blk: {
            if (rc.row == 0) return false;
            break :blk rc.row - 1;
        } else rc.row + 1;

        const text = self.buf.items;
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i <= text.len) {
            if (row == target_row) {
                self.cursor = findColInRow(text, width, i, rc.col);
                self.follow_cursor = true;
                return true;
            }
            if (i >= text.len) break;
            const dec = decodeAt(text, i);
            if (dec.cp == '\n') {
                row += 1;
                col = 0;
                i += dec.len;
                continue;
            }
            const w: usize = codepointWidth(dec.cp);
            if (w > 0 and col + w > width and col > 0) {
                row += 1;
                col = 0;
                continue;
            }
            col += w;
            i += dec.len;
        }
        return false;
    }

    /// 手动滚动视口（up = 查看更早的行）；仅移动视口，不改光标
    pub fn scrollView(self: *Self, up: bool, width: usize, height: usize) void {
        if (height == 0 or width == 0) return;
        const total = self.lineCount(width);
        const max_start = total -| height;
        if (up) {
            self.view_start -|= 1; // 视口顶行上移 = 显示更早的内容
        } else {
            self.view_start +|= 1;
            if (self.view_start > max_start) self.view_start = max_start;
        }
        self.follow_cursor = false;
    }

    /// 设置光标位置（保持在码点边界）；不改动视口（用于鼠标点击定位）
    pub fn setCursor(self: *Self, off: usize) void {
        var o = @min(off, self.buf.items.len);
        while (o > 0 and o < self.buf.items.len and (self.buf.items[o] & 0xC0) == 0x80) : (o -= 1) {}
        self.cursor = o;
        self.follow_cursor = false;
    }

    /// 应用视口（每帧绘制前调用）：钳制滚动范围；
    /// 若光标需要跟随（编辑/键盘移动后），确保光标可见
    pub fn applyViewport(self: *Self, width: usize, height: usize) void {
        if (width == 0 or height == 0) return;
        const total = self.lineCount(width);
        const max_start = total -| height;
        if (self.follow_cursor) {
            const rc = self.cursorRowCol(width);
            if (rc.row < self.view_start) {
                self.view_start = rc.row;
            }
            if (rc.row >= self.view_start + height) {
                self.view_start = rc.row - height + 1;
            }
            self.follow_cursor = false;
        }
        if (self.view_start > max_start) self.view_start = max_start;
    }

    pub fn canScrollUp(self: *const Self) bool {
        return self.view_start > 0;
    }

    pub fn canScrollDown(self: *const Self, width: usize, height: usize) bool {
        if (height == 0 or width == 0) return false;
        const total = self.lineCount(width);
        return self.view_start + height < total;
    }

    /// 光标所在的可视行列
    pub fn cursorRowCol(self: *const Self, width: usize) RowCol {
        const text = self.buf.items;
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i < self.cursor) {
            const dec = decodeAt(text, i);
            if (dec.cp == '\n') {
                row += 1;
                col = 0;
                i += dec.len;
                continue;
            }
            const w: usize = codepointWidth(dec.cp);
            if (width > 0 and w > 0 and col + w > width and col > 0) {
                row += 1;
                col = 0;
            }
            col += w;
            i += dec.len;
        }
        if (width > 0 and col >= width) {
            row += 1;
            col = 0;
        }
        return .{ .row = row, .col = col };
    }

    /// 按宽度折行后的总行数（含光标所在行，至少 1）
    pub fn lineCount(self: *const Self, width: usize) usize {
        var it = RowIter{ .text = self.buf.items, .width = width };
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        const rc = self.cursorRowCol(width);
        return @max(@max(n, 1), rc.row + 1);
    }

    /// 第 row_index 个可视行的字节范围（不含换行符）；不存在返回 null
    pub fn rowByteRange(self: *const Self, width: usize, row_index: usize) ?[2]usize {
        var it = RowIter{ .text = self.buf.items, .width = width };
        var i: usize = 0;
        while (it.next()) |r| : (i += 1) {
            if (i == row_index) return .{ r.start, r.end };
        }
        return null;
    }

    pub fn render(self: *const Self, area: Rect, buf: *Buffer) void {
        if (area.width == 0 or area.height == 0) return;
        const text = self.buf.items;
        const width: usize = area.width;

        if (text.len == 0) {
            if (self.placeholder.len > 0) {
                buf.setStringTruncated(area.x, area.y, self.placeholder, area.width, self.placeholder_style);
            }
            var x = area.x;
            if (self.draw_fake_cursor and self.focused and self.blink_on) {
                buf.setChar(x, area.y, ' ', self.style.merge(self.cursor_style));
                x +|= 1;
            }
            while (x < area.x +| area.width) : (x += 1) {
                buf.setChar(x, area.y, ' ', self.style);
            }
            // 清空其余行
            var y = area.y +| 1;
            while (y < area.y +| area.height) : (y += 1) {
                var xx = area.x;
                while (xx < area.x +| area.width) : (xx += 1) {
                    buf.setChar(xx, y, ' ', self.style);
                }
            }
            return;
        }

        const rc = self.cursorRowCol(width);
        const view_start = self.view_start;

        var it = RowIter{ .text = text, .width = width };
        var row: usize = 0;
        var y = area.y;
        var cursor_drawn = false;
        while (it.next()) |r| {
            if (row < view_start) {
                row += 1;
                continue;
            }
            if (y >= area.y + area.height) break;

            var x = area.x;
            var col: usize = 0;
            var i = r.start;
            while (i < r.end) {
                const dec = decodeAt(text, i);
                const w: usize = codepointWidth(dec.cp);
                const selected = self.isSelected(i);
                if (self.draw_fake_cursor and self.focused and self.blink_on and row == rc.row and col == rc.col) {
                    const cs = if (self.cursorSelected()) self.cursor_sel_style else self.cursor_style;
                    buf.setChar(x, y, dec.cp, self.style.merge(cs));
                    cursor_drawn = true;
                } else if (selected) {
                    buf.setChar(x, y, dec.cp, self.style.merge(.{ .modifier = .{ .reversed = true } }));
                } else {
                    buf.setChar(x, y, dec.cp, self.style);
                }
                x +|= @intCast(w);
                col += w;
                i += dec.len;
            }
            // 行尾光标
            if (self.draw_fake_cursor and self.focused and self.blink_on and row == rc.row and rc.col >= col) {
                const cs = if (self.cursorSelected()) self.cursor_sel_style else self.cursor_style;
                buf.setChar(x, y, ' ', self.style.merge(cs));
                x +|= 1;
                cursor_drawn = true;
            }
            while (x < area.x +| area.width) : (x += 1) {
                buf.setChar(x, y, ' ', self.style);
            }
            y += 1;
            row += 1;
        }

        // 光标位于折行边界（落在虚拟的下一行行首；仅在光标行仍处于视口内时绘制）
        if (self.draw_fake_cursor and self.focused and self.blink_on and !cursor_drawn and rc.row >= view_start) {
            const offset = rc.row - view_start;
            if (offset < area.height) {
                const cy = area.y +| @as(u16, @intCast(@min(offset, 0xFFFF)));
                var x = area.x;
                const cs = if (self.cursorSelected()) self.cursor_sel_style else self.cursor_style;
                buf.setChar(x, cy, ' ', self.style.merge(cs));
                x +|= 1;
                while (x < area.x +| area.width) : (x += 1) {
                    buf.setChar(x, cy, ' ', self.style);
                }
            }
        }
    }

    fn isSelected(self: *const Self, off: usize) bool {
        const r = self.sel_range orelse return false;
        return off >= r[0] and off < r[1];
    }

    /// 光标是否落在选区上（含两端边界）
    fn cursorSelected(self: *const Self) bool {
        const r = self.sel_range orelse return false;
        return self.cursor >= r[0] and self.cursor <= r[1];
    }

    fn prevCpLen(self: *const Self) usize {
        var i = self.cursor;
        while (i > 0) {
            i -= 1;
            if (self.buf.items[i] & 0xC0 != 0x80) break;
        }
        return self.cursor - i;
    }

    fn nextCpLen(self: *const Self) usize {
        if (self.cursor >= self.buf.items.len) return 0;
        const n = std.unicode.utf8ByteSequenceLength(self.buf.items[self.cursor]) catch return 1;
        return @min(n, self.buf.items.len - self.cursor);
    }
};

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

/// 从行首 start 起，找到列 >= target_col 的字节位置（不超过该行行尾）
fn findColInRow(text: []const u8, width: usize, start: usize, target_col: usize) usize {
    var col: usize = 0;
    var i = start;
    while (i < text.len) {
        const dec = decodeAt(text, i);
        if (dec.cp == '\n') return i;
        const w: usize = codepointWidth(dec.cp);
        if (w > 0 and col + w > width and col > 0) return i; // 软换行行尾
        if (w > 0 and col >= target_col) return i;
        col += w;
        i += dec.len;
    }
    return text.len;
}

const Row = struct { start: usize, end: usize };

/// 按显示宽度迭代可视行（含文末空行）
const RowIter = struct {
    text: []const u8,
    width: usize,
    i: usize = 0,
    done: bool = false,

    fn next(self: *RowIter) ?Row {
        if (self.done) return null;
        if (self.i >= self.text.len) {
            self.done = true;
            if (self.text.len == 0 or self.text[self.text.len - 1] == '\n') {
                return .{ .start = self.i, .end = self.i };
            }
            return null;
        }
        const start = self.i;
        var col: usize = 0;
        var i = self.i;
        while (i < self.text.len) {
            const dec = decodeAt(self.text, i);
            if (dec.cp == '\n') {
                self.i = i + dec.len;
                return .{ .start = start, .end = i };
            }
            const w: usize = codepointWidth(dec.cp);
            if (self.width > 0 and w > 0 and col + w > self.width and col > 0) {
                self.i = i;
                return .{ .start = start, .end = i };
            }
            col += w;
            i += dec.len;
        }
        self.i = self.text.len;
        return .{ .start = start, .end = i };
    }
};

// ── 测试 ──

const testing = std.testing;

test "TextArea: 插入与删除（含换行）" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertCodepoint('a');
    ta.insertCodepoint('\n');
    ta.insertCodepoint('b');
    try testing.expectEqualStrings("a\nb", ta.value());
    try testing.expectEqual(@as(usize, 3), ta.cursor);

    ta.deleteBackward();
    try testing.expectEqualStrings("a\n", ta.value());
    ta.deleteBackward();
    try testing.expectEqualStrings("a", ta.value());
}

test "TextArea: 行列与折行计数" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("abcd");
    // 宽度 4：恰好一行，但光标处于折行边界（占一个虚拟行）
    try testing.expectEqual(@as(usize, 2), ta.lineCount(4));
    // 宽度 2：两行 + 光标虚拟行
    try testing.expectEqual(@as(usize, 3), ta.lineCount(2));

    ta.insertCodepoint('\n');
    ta.insertBytes("中文");
    // "abcd\n中文"，宽度 4：abcd / 中文 / 光标虚拟行
    try testing.expectEqual(@as(usize, 3), ta.lineCount(4));

    const rc = ta.cursorRowCol(4);
    try testing.expectEqual(@as(usize, 2), rc.row);
    try testing.expectEqual(@as(usize, 0), rc.col);
}

test "TextArea: 动态扩容与软上限" {
    const allocator = testing.allocator;
    var ta = TextArea{ .allocator = allocator };
    defer ta.deinit();

    // 远超旧固定容量（64KB）：完整保留
    const chunk = "中文abc\n"; // 10 字节
    for (0..10_000) |_| {
        try testing.expectEqual(chunk.len, ta.insertBytesTruncated(chunk));
    }
    try testing.expectEqual(@as(usize, 100_000), ta.byteLen());
    try testing.expect(std.unicode.utf8ValidateSlice(ta.value()));

    // 一直插到软上限：上限处截断，不切开多字节字符
    const rest = max_input_bytes - ta.byteLen();
    const filler = try allocator.alloc(u8, rest + 8);
    defer allocator.free(filler);
    @memset(filler, 'x');
    const inserted = ta.insertBytesTruncated(filler);
    try testing.expect(inserted <= filler.len);
    try testing.expectEqual(max_input_bytes, ta.byteLen());
    // 达到上限后再插：返回 0，不产生半个字符
    try testing.expectEqual(@as(usize, 0), ta.insertBytesTruncated("中"));
    try testing.expect(std.unicode.utf8ValidateSlice(ta.value()));

    // 只留 2 字节空间：3 字节汉字放不下（不切开），ASCII 可以
    var ta2 = TextArea{ .allocator = allocator };
    defer ta2.deinit();
    const filler2 = try allocator.alloc(u8, max_input_bytes - 2);
    defer allocator.free(filler2);
    @memset(filler2, 'y');
    try testing.expectEqual(filler2.len, ta2.insertBytesTruncated(filler2));
    try testing.expectEqual(@as(usize, 0), ta2.insertBytesTruncated("中"));
    try testing.expectEqual(@as(usize, 2), ta2.insertBytesTruncated("ab"));
    try testing.expect(std.unicode.utf8ValidateSlice(ta2.value()));
}

test "TextArea: 上下移动保持列位置" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("abcdef\nxy\nabcdef");
    // 光标移到末尾（第三行末）
    ta.moveCursorEnd();
    var rc = ta.cursorRowCol(20);
    try testing.expectEqual(@as(usize, 2), rc.row);
    try testing.expectEqual(@as(usize, 6), rc.col);

    // 上移：第二行只有 2 列 → 光标停在行尾
    try testing.expect(ta.moveCursorVert(20, true));
    rc = ta.cursorRowCol(20);
    try testing.expectEqual(@as(usize, 1), rc.row);
    try testing.expectEqual(@as(usize, 2), rc.col);

    // 再上移：第一行第 2 列
    try testing.expect(ta.moveCursorVert(20, true));
    rc = ta.cursorRowCol(20);
    try testing.expectEqual(@as(usize, 0), rc.row);
    try testing.expectEqual(@as(usize, 2), rc.col);

    // 已在首行 → 返回 false
    try testing.expect(!ta.moveCursorVert(20, true));

    // 下移两次到第三行第 2 列
    try testing.expect(ta.moveCursorVert(20, false));
    try testing.expect(ta.moveCursorVert(20, false));
    rc = ta.cursorRowCol(20);
    try testing.expectEqual(@as(usize, 2), rc.row);
    try testing.expectEqual(@as(usize, 2), rc.col);

    // 已在末行 → 返回 false
    try testing.expect(!ta.moveCursorVert(20, false));
}

test "TextArea: Home/End 在逻辑行内移动" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("abc\ndefg");
    ta.moveCursorEnd();
    ta.moveCursorLineHome();
    try testing.expectEqual(@as(usize, 4), ta.cursor);
    ta.moveCursorLineEnd();
    try testing.expectEqual(@as(usize, 8), ta.cursor);
}

test "TextArea: 渲染折行到多行区域" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("abcdefgh");

    var buf = try Buffer.init(testing.allocator, 8, 4);
    defer buf.deinit();

    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 3 }, &buf);

    // 第一行 "abcd"，第二行 "efgh"（宽度 4 折行）
    var line0: [4]u8 = undefined;
    for (0..4) |i| line0[i] = @intCast(buf.get(@intCast(i), 0).?.char);
    try testing.expectEqualStrings("abcd", &line0);

    var line1: [4]u8 = undefined;
    for (0..4) |i| line1[i] = @intCast(buf.get(@intCast(i), 1).?.char);
    try testing.expectEqualStrings("efgh", &line1);
}

test "TextArea: 视口与按行字节范围" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("abcdefgh"); // 宽度 4 → 两行
    ta.moveCursorEnd();

    // 光标在折行边界的虚拟行（row 2），视口高度 2 → 从第 1 行开始显示
    ta.applyViewport(4, 2);
    try testing.expectEqual(@as(usize, 1), ta.view_start);
    ta.applyViewport(4, 3);
    try testing.expectEqual(@as(usize, 0), ta.view_start);

    const r1 = ta.rowByteRange(4, 1).?;
    try testing.expectEqual(@as(usize, 4), r1[0]);
    try testing.expectEqual(@as(usize, 8), r1[1]);

    // 换行符不计入行范围
    ta.clear();
    ta.insertBytes("ab\ncdef");
    const r0 = ta.rowByteRange(4, 0).?;
    try testing.expectEqual(@as(usize, 0), r0[0]);
    try testing.expectEqual(@as(usize, 2), r0[1]); // "ab"，不含 \n
    const r2 = ta.rowByteRange(4, 1).?;
    try testing.expectEqual(@as(usize, 3), r2[0]);
    try testing.expectEqual(@as(usize, 7), r2[1]); // "cdef"

    try testing.expect(ta.rowByteRange(4, 9) == null);
}

test "TextArea: 视口跟随、手动滚动与点击定位" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("aaaaaaaaaaaa"); // 宽度 4 → 3 行内容
    ta.moveCursorEnd();

    // 光标跟随：光标在虚拟行 3，视口高度 2 → 显示最后两行
    ta.applyViewport(4, 2);
    try testing.expectEqual(@as(usize, 2), ta.view_start);
    try testing.expect(!ta.canScrollDown(4, 2));
    try testing.expect(ta.canScrollUp());

    // 手动向上滚动
    ta.scrollView(true, 4, 2);
    try testing.expectEqual(@as(usize, 1), ta.view_start);
    ta.scrollView(true, 4, 2);
    ta.scrollView(true, 4, 2);
    try testing.expectEqual(@as(usize, 0), ta.view_start);
    try testing.expect(!ta.canScrollUp());
    try testing.expect(ta.canScrollDown(4, 2));

    // 向下滚回
    ta.scrollView(false, 4, 2);
    try testing.expectEqual(@as(usize, 1), ta.view_start);

    // 光标移动后视口重新跟随
    ta.moveCursorLeft();
    ta.applyViewport(4, 2);
    try testing.expectEqual(@as(usize, 1), ta.view_start);
    ta.moveCursorHome();
    ta.applyViewport(4, 2);
    try testing.expectEqual(@as(usize, 0), ta.view_start);

    // 点击定位光标：不改变视口
    ta.moveCursorEnd();
    ta.applyViewport(4, 2);
    try testing.expectEqual(@as(usize, 2), ta.view_start);
    ta.scrollView(true, 4, 2); // 手动上滚到第 1 行
    try testing.expectEqual(@as(usize, 1), ta.view_start);
    ta.setCursor(1);
    ta.applyViewport(4, 2);
    try testing.expectEqual(@as(usize, 1), ta.view_start); // 视口保持
    try testing.expectEqual(@as(usize, 1), ta.cursor);
}

test "TextArea: deleteRange 删除选区" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("hello world");
    ta.deleteRange(0, 6); // 删除 "hello "
    try testing.expectEqualStrings("world", ta.value());
    try testing.expectEqual(@as(usize, 0), ta.cursor);

    // 越界裁剪
    ta.deleteRange(3, 99);
    try testing.expectEqualStrings("wor", ta.value());
    try testing.expectEqual(@as(usize, 3), ta.cursor);

    // 空区间/反向区间安全
    ta.deleteRange(2, 1);
    try testing.expectEqualStrings("wor", ta.value());

    // 中文（多字节）删除
    ta.clear();
    ta.insertBytes("中文字符");
    ta.deleteRange(3, 6); // 删除 "文"
    try testing.expectEqualStrings("中字符", ta.value());
}

test "TextArea: 光标闪烁开关影响光标块" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("ab");
    ta.style = .{ .fg = .white };
    ta.cursor_style = .{ .fg = .black, .bg = .white };

    var buf = try Buffer.init(testing.allocator, 4, 1);
    defer buf.deinit();

    // 闪烁关闭：光标位置（"ab" 之后的空格）无光标底色
    ta.blink_on = false;
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, &buf);
    try testing.expect(buf.get(2, 0).?.bg.eql(.reset));

    // 闪烁开启：出现光标底色（白底）
    ta.blink_on = true;
    buf.clear();
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, &buf);
    try testing.expect(buf.get(2, 0).?.bg.eql(.white));
}

test "TextArea: draw_fake_cursor 关闭时不绘制方块光标（主输入框用真实终端光标）" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("ab");
    ta.style = .{ .fg = .white };
    ta.cursor_style = .{ .fg = .black, .bg = .white };
    ta.blink_on = true;

    var buf = try Buffer.init(testing.allocator, 4, 1);
    defer buf.deinit();

    // 开启（默认）：光标格（"ab" 之后）为白底方块
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, &buf);
    try testing.expect(buf.get(2, 0).?.bg.eql(.white));

    // 关闭：无方块（该格保持普通底色；文本本身不受影响）
    ta.draw_fake_cursor = false;
    buf.clear();
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, &buf);
    try testing.expect(buf.get(2, 0).?.bg.eql(.reset));
    try testing.expectEqual(@as(u21, 'a'), buf.get(0, 0).?.char);
    try testing.expectEqual(@as(u21, 'b'), buf.get(1, 0).?.char);
}

test "TextArea: 光标落在选中字符上时使用灰底光标" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("ab");
    ta.style = .{ .fg = .white };
    ta.cursor_style = .{ .fg = .black, .bg = .white };
    ta.cursor_sel_style = .{ .fg = .black, .bg = .dark_gray };
    ta.sel_range = .{ 0, 2 };

    // 光标移到 'b'（字节 1）
    ta.moveCursorLeft();
    ta.blink_on = true;

    var buf = try Buffer.init(testing.allocator, 4, 1);
    defer buf.deinit();
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, &buf);

    // 'a' 选中无光标：反色修饰符
    try testing.expect(buf.get(0, 0).?.modifier.reversed);
    // 'b' 光标 + 选中：灰底光标
    try testing.expect(buf.get(1, 0).?.bg.eql(.dark_gray));

    // 闪烁关闭：'b' 恢复为普通选中（反色）
    ta.blink_on = false;
    buf.clear();
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, &buf);
    try testing.expect(buf.get(1, 0).?.modifier.reversed);

    // 无选区时：光标用普通白底
    ta.sel_range = null;
    ta.blink_on = true;
    buf.clear();
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, &buf);
    try testing.expect(buf.get(1, 0).?.bg.eql(.white));
}

test "TextArea: 光标滚出视口后不再绘制" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("aaaaaaaaaaaa"); // 宽度 4 → 3 行内容
    ta.moveCursorHome(); // 光标在第 0 行
    ta.applyViewport(4, 2);

    // 手动向下滚动一行：光标行（0）滚出视口
    ta.scrollView(false, 4, 2);
    try testing.expectEqual(@as(usize, 1), ta.view_start);

    ta.style = .{ .fg = .white };
    ta.cursor_style = .{ .fg = .black, .bg = .white };
    ta.blink_on = true;

    var buf = try Buffer.init(testing.allocator, 4, 2);
    defer buf.deinit();
    ta.render(.{ .x = 0, .y = 0, .width = 4, .height = 2 }, &buf);

    // 视口内不应出现光标底色（光标已滚出）
    for (0..4) |x| {
        try testing.expect(!buf.get(@intCast(x), 0).?.bg.eql(.white));
        try testing.expect(!buf.get(@intCast(x), 1).?.bg.eql(.white));
    }
}

test "TextArea: 软换行下的上下移动" {
    var ta = TextArea{ .allocator = testing.allocator };
    defer ta.deinit();
    ta.insertBytes("abcdefgh"); // 宽度 4 → 两行
    ta.moveCursorEnd();
    var rc = ta.cursorRowCol(4);
    // 光标在折行边界 → 虚拟的下一行行首
    try testing.expectEqual(@as(usize, 2), rc.row);
    try testing.expectEqual(@as(usize, 0), rc.col);

    try testing.expect(ta.moveCursorVert(4, true));
    rc = ta.cursorRowCol(4);
    try testing.expectEqual(@as(usize, 1), rc.row);
    try testing.expectEqual(@as(usize, 0), rc.col);

    try testing.expect(ta.moveCursorVert(4, true));
    rc = ta.cursorRowCol(4);
    try testing.expectEqual(@as(usize, 0), rc.row);
    try testing.expectEqual(@as(usize, 0), rc.col);

    try testing.expect(!ta.moveCursorVert(4, true));
}
