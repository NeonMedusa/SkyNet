const std = @import("std");
const Allocator = std.mem.Allocator;

/// 支持的正则子集：
///   字面量 . * + ? [..] [^..] ^ $ | ( ) 以及 \d \D \w \W \s \S 与转义
/// 无捕获组（括号仅分组），回溯匹配，带步数与深度上限防病态模式。
const max_class_ranges = 32;

const ClassRange = struct { lo: u21, hi: u21 };

const CharClass = struct {
    negate: bool = false,
    count: u8 = 0,
    ranges: [max_class_ranges]ClassRange = undefined,

    fn add(self: *CharClass, lo: u21, hi: u21) void {
        if (self.count >= max_class_ranges) return;
        self.ranges[self.count] = .{ .lo = lo, .hi = hi };
        self.count += 1;
    }

    fn addDigit(self: *CharClass) void {
        self.add('0', '9');
    }

    fn addWord(self: *CharClass) void {
        self.add('0', '9');
        self.add('A', 'Z');
        self.add('a', 'z');
        self.add('_', '_');
    }

    fn addSpace(self: *CharClass) void {
        self.add(' ', ' ');
        self.add('\t', '\t');
        self.add('\n', '\n');
        self.add('\r', '\r');
        self.add(0x0B, 0x0C);
    }

    fn matches(self: CharClass, cp: u21) bool {
        var hit = false;
        for (self.ranges[0..self.count]) |r| {
            if (cp >= r.lo and cp <= r.hi) {
                hit = true;
                break;
            }
        }
        return hit != self.negate;
    }
};

const Inst = union(enum) {
    char: u21,
    any,
    class: CharClass,
    bol,
    eol,
    split: struct { a: u32, b: u32 },
    jump: u32,
    accept,
};

const Node = union(enum) {
    empty,
    lit: u21,
    any,
    class: CharClass,
    bol,
    eol,
    concat: []Node,
    alt: []Node,
    star: struct { child: *Node, min: u8, max: ?u8 },
};

const ParseError = error{ InvalidPattern, OutOfMemory };

const Parser = struct {
    pattern: []const u8,
    pos: usize = 0,
    arena: Allocator,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.pattern.len) return null;
        return self.pattern[self.pos];
    }

    fn next(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        return c;
    }

    fn parseAlt(self: *Parser) ParseError!Node {
        var branches = std.ArrayListUnmanaged(Node){ .items = &.{}, .capacity = 0 };
        try branches.append(self.arena, try self.parseConcat());
        while (self.peek() == @as(u8, '|')) {
            _ = self.next();
            try branches.append(self.arena, try self.parseConcat());
        }
        const items = try branches.toOwnedSlice(self.arena);
        if (items.len == 1) return items[0];
        return .{ .alt = items };
    }

    fn parseConcat(self: *Parser) ParseError!Node {
        var items = std.ArrayListUnmanaged(Node){ .items = &.{}, .capacity = 0 };
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try items.append(self.arena, try self.parseRepeat());
        }
        const slice = try items.toOwnedSlice(self.arena);
        if (slice.len == 0) return .empty;
        if (slice.len == 1) return slice[0];
        return .{ .concat = slice };
    }

    fn parseRepeat(self: *Parser) ParseError!Node {
        var node = try self.parseAtom();
        while (self.peek()) |c| {
            switch (c) {
                '*' => {
                    _ = self.next();
                    const child = try self.arena.create(Node);
                    child.* = node;
                    node = .{ .star = .{ .child = child, .min = 0, .max = null } };
                },
                '+' => {
                    _ = self.next();
                    const child = try self.arena.create(Node);
                    child.* = node;
                    node = .{ .star = .{ .child = child, .min = 1, .max = null } };
                },
                '?' => {
                    _ = self.next();
                    const child = try self.arena.create(Node);
                    child.* = node;
                    node = .{ .star = .{ .child = child, .min = 0, .max = 1 } };
                },
                else => break,
            }
        }
        return node;
    }

    fn parseAtom(self: *Parser) ParseError!Node {
        const c = self.next() orelse return error.InvalidPattern;
        switch (c) {
            '.' => return .any,
            '^' => return .bol,
            '$' => return .eol,
            '(' => {
                const inner = try self.parseAlt();
                if (self.next() != @as(u8, ')')) return error.InvalidPattern;
                return inner;
            },
            '[' => return self.parseClass(),
            '\\' => return self.parseEscape(),
            ')', '|', '*', '+', '?' => return error.InvalidPattern,
            else => return .{ .lit = try decodeChar(self.pattern, &self.pos, c) },
        }
    }

    fn parseEscape(self: *Parser) ParseError!Node {
        const c = self.next() orelse return error.InvalidPattern;
        var class = CharClass{};
        switch (c) {
            'd' => {
                class.addDigit();
                return .{ .class = class };
            },
            'D' => {
                class.negate = true;
                class.addDigit();
                return .{ .class = class };
            },
            'w' => {
                class.addWord();
                return .{ .class = class };
            },
            'W' => {
                class.negate = true;
                class.addWord();
                return .{ .class = class };
            },
            's' => {
                class.addSpace();
                return .{ .class = class };
            },
            'S' => {
                class.negate = true;
                class.addSpace();
                return .{ .class = class };
            },
            'n' => return .{ .lit = '\n' },
            't' => return .{ .lit = '\t' },
            'r' => return .{ .lit = '\r' },
            else => return .{ .lit = try decodeChar(self.pattern, &self.pos, c) },
        }
    }

    fn parseClass(self: *Parser) ParseError!Node {
        var class = CharClass{};
        if (self.peek() == @as(u8, '^')) {
            _ = self.next();
            class.negate = true;
        }
        var first = true;
        while (true) {
            const c = self.next() orelse return error.InvalidPattern;
            if (c == ']' and !first) break;
            first = false;

            var lo: u21 = undefined;
            if (c == '\\') {
                const e = self.next() orelse return error.InvalidPattern;
                switch (e) {
                    'd' => {
                        class.addDigit();
                        continue;
                    },
                    'w' => {
                        class.addWord();
                        continue;
                    },
                    's' => {
                        class.addSpace();
                        continue;
                    },
                    'n' => lo = '\n',
                    't' => lo = '\t',
                    'r' => lo = '\r',
                    else => lo = try decodeChar(self.pattern, &self.pos, e),
                }
            } else {
                lo = try decodeChar(self.pattern, &self.pos, c);
            }

            // 范围 a-z
            if (self.peek() == @as(u8, '-') and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                _ = self.next();
                const hc = self.next() orelse return error.InvalidPattern;
                var hi: u21 = undefined;
                if (hc == '\\') {
                    const e = self.next() orelse return error.InvalidPattern;
                    hi = try decodeChar(self.pattern, &self.pos, e);
                } else {
                    hi = try decodeChar(self.pattern, &self.pos, hc);
                }
                if (hi < lo) return error.InvalidPattern;
                class.add(lo, hi);
            } else {
                class.add(lo, lo);
            }
        }
        return .{ .class = class };
    }
};

/// 解码一个字符（处理多字节 UTF-8；c 为已消费的首字节）
fn decodeChar(pattern: []const u8, pos: *usize, c: u8) ParseError!u21 {
    if (c < 0x80) return c;
    const start = pos.* - 1;
    const len = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidPattern;
    if (start + len > pattern.len) return error.InvalidPattern;
    pos.* = start + len;
    return std.unicode.utf8Decode(pattern[start .. start + len]) catch error.InvalidPattern;
}

const Compiler = struct {
    out: std.ArrayListUnmanaged(Inst) = .{ .items = &.{}, .capacity = 0 },
    allocator: Allocator,
    scratch: Allocator,

    fn emit(self: *Compiler, node: Node) ParseError!void {
        switch (node) {
            .empty => {},
            .lit => |cp| try self.out.append(self.allocator, .{ .char = cp }),
            .any => try self.out.append(self.allocator, .any),
            .class => |cl| try self.out.append(self.allocator, .{ .class = cl }),
            .bol => try self.out.append(self.allocator, .bol),
            .eol => try self.out.append(self.allocator, .eol),
            .concat => |items| {
                for (items) |item| try self.emit(item);
            },
            .alt => |branches| try self.emitAlt(branches),
            .star => |s| try self.emitStar(s),
        }
    }

    fn emitAlt(self: *Compiler, branches: []Node) ParseError!void {
        if (branches.len == 0) return;
        if (branches.len == 1) {
            try self.emit(branches[0]);
            return;
        }
        var end_jumps = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
        defer end_jumps.deinit(self.scratch);

        for (branches, 0..) |branch, i| {
            if (i + 1 < branches.len) {
                const split_pc = self.out.items.len;
                try self.out.append(self.allocator, .{ .split = .{ .a = 0, .b = 0 } });
                try self.emit(branch);
                const jump_pc = self.out.items.len;
                try self.out.append(self.allocator, .{ .jump = 0 });
                try end_jumps.append(self.scratch, jump_pc);
                self.out.items[split_pc].split.a = @intCast(split_pc + 1);
                self.out.items[split_pc].split.b = @intCast(self.out.items.len);
            } else {
                try self.emit(branch);
            }
        }

        const end_pc: u32 = @intCast(self.out.items.len);
        for (end_jumps.items) |j| self.out.items[j].jump = end_pc;
    }

    fn emitStar(self: *Compiler, s: anytype) ParseError!void {
        switch (s.min) {
            0 => {
                if (s.max != null) {
                    // x?
                    const split_pc = self.out.items.len;
                    try self.out.append(self.allocator, .{ .split = .{ .a = 0, .b = 0 } });
                    try self.emit(s.child.*);
                    self.out.items[split_pc].split.a = @intCast(split_pc + 1);
                    self.out.items[split_pc].split.b = @intCast(self.out.items.len);
                } else {
                    // x*
                    const split_pc = self.out.items.len;
                    try self.out.append(self.allocator, .{ .split = .{ .a = 0, .b = 0 } });
                    try self.emit(s.child.*);
                    try self.out.append(self.allocator, .{ .jump = @intCast(split_pc) });
                    self.out.items[split_pc].split.a = @intCast(split_pc + 1);
                    self.out.items[split_pc].split.b = @intCast(self.out.items.len);
                }
            },
            else => {
                // x+
                const start_pc: u32 = @intCast(self.out.items.len);
                try self.emit(s.child.*);
                const split_pc = self.out.items.len;
                try self.out.append(self.allocator, .{ .split = .{ .a = start_pc, .b = 0 } });
                self.out.items[split_pc].split.b = @intCast(split_pc + 1);
            },
        }
    }

    fn finish(self: *Compiler) ParseError![]Inst {
        try self.out.append(self.allocator, .accept);
        return self.allocator.dupe(Inst, self.out.items);
    }
};

const max_budget = 2_000_000;
const max_depth = 4096;

fn decodeAt(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const c = text[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
    if (i + len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = std.unicode.utf8Decode(text[i .. i + len]) catch 0xFFFD, .len = len };
}

fn foldCp(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return cp;
}

fn run(prog: []const Inst, text: []const u8, pc: u32, pos: usize, budget: *u32, depth: u32, folds: bool) ?usize {
    if (budget.* == 0 or depth > max_depth) return null;
    budget.* -= 1;
    switch (prog[pc]) {
        .char => |c| {
            if (pos >= text.len) return null;
            const dec = decodeAt(text, pos);
            const a = if (folds) foldCp(dec.cp) else dec.cp;
            const b = if (folds) foldCp(c) else c;
            if (a != b) return null;
            return run(prog, text, pc + 1, pos + dec.len, budget, depth + 1, folds);
        },
        .any => {
            if (pos >= text.len) return null;
            const dec = decodeAt(text, pos);
            if (dec.cp == '\n') return null;
            return run(prog, text, pc + 1, pos + dec.len, budget, depth + 1, folds);
        },
        .class => |cl| {
            if (pos >= text.len) return null;
            const dec = decodeAt(text, pos);
            var cp = dec.cp;
            if (folds) cp = foldCp(cp);
            var matched = cl.matches(cp);
            if (!matched and folds) {
                // 大小写折叠后可能落入 A-Z 区间
                matched = cl.matches(dec.cp);
            }
            if (!matched) return null;
            return run(prog, text, pc + 1, pos + dec.len, budget, depth + 1, folds);
        },
        .bol => {
            if (pos != 0) return null;
            return run(prog, text, pc + 1, pos, budget, depth + 1, folds);
        },
        .eol => {
            if (pos != text.len) return null;
            return run(prog, text, pc + 1, pos, budget, depth + 1, folds);
        },
        .split => |s| {
            if (run(prog, text, s.a, pos, budget, depth + 1, folds)) |end| return end;
            return run(prog, text, s.b, pos, budget, depth + 1, folds);
        },
        .jump => |t| return run(prog, text, t, pos, budget, depth + 1, folds),
        .accept => return pos,
    }
}

pub const Options = struct {
    ignore_case: bool = false,
};

pub const Regex = struct {
    allocator: Allocator,
    prog: []Inst = &.{},
    folds: bool = false,

    pub fn compile(allocator: Allocator, pattern: []const u8, options: Options) !Regex {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var parser = Parser{ .pattern = pattern, .arena = arena };
        const root = try parser.parseAlt();
        if (parser.pos != pattern.len) return error.InvalidPattern;

        var compiler = Compiler{ .allocator = allocator, .scratch = arena };
        defer compiler.out.deinit(allocator);
        try compiler.emit(root);
        const prog = try compiler.finish();
        return .{ .allocator = allocator, .prog = prog, .folds = options.ignore_case };
    }

    pub fn deinit(self: *Regex) void {
        if (self.prog.len > 0) self.allocator.free(self.prog);
        self.prog = &.{};
    }

    /// 从左到右找第一个非空匹配，返回 [start, end) 字节区间
    pub fn find(self: *const Regex, text: []const u8) ?[2]usize {
        var budget: u32 = max_budget;
        var start: usize = 0;
        while (start <= text.len) {
            if (run(self.prog, text, 0, start, &budget, 0, self.folds)) |end| {
                if (end > start) return .{ start, end };
            }
            if (start == text.len) break;
            const dec = decodeAt(text, start);
            start += dec.len;
        }
        return null;
    }

    /// 在给定文本中是否存在匹配（允许零宽匹配，例如锚点 ^ $）。
    /// grep 用它判定“某行是否命中”，因此不能像 find 那样跳过空匹配。
    pub fn matchesAny(self: *const Regex, text: []const u8) bool {
        var budget: u32 = max_budget;
        var start: usize = 0;
        while (start <= text.len) {
            if (run(self.prog, text, 0, start, &budget, 0, self.folds) != null) return true;
            if (start == text.len) break;
            const dec = decodeAt(text, start);
            start += dec.len;
        }
        return false;
    }

    /// 在指定位置起是否匹配（用于测试/调试）
    pub fn matchAt(self: *const Regex, text: []const u8, start: usize) ?usize {
        var budget: u32 = max_budget;
        return run(self.prog, text, 0, start, &budget, 0, self.folds);
    }
};

// ── 测试 ──

const testing = std.testing;

fn expectFind(pattern: []const u8, text: []const u8, expected: ?[2]usize) !void {
    var re = try Regex.compile(testing.allocator, pattern, .{});
    defer re.deinit();
    const got = re.find(text);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqual(e[0], got.?[0]);
        try testing.expectEqual(e[1], got.?[1]);
    } else {
        try testing.expect(got == null);
    }
}

test "regex: 字面量与位置" {
    try expectFind("abc", "xxabcxx", .{ 2, 5 });
    try expectFind("abc", "abx", null);
    try expectFind("", "abc", null); // 空匹配被跳过
}

test "regex: 点号与量词" {
    try expectFind("a.c", "azc", .{ 0, 3 });
    try expectFind("a.c", "ac", null);
    try expectFind("ab*c", "ac", .{ 0, 2 });
    try expectFind("ab*c", "abbbc", .{ 0, 5 });
    try expectFind("ab+c", "ac", null);
    try expectFind("ab+c", "abbc", .{ 0, 4 });
    try expectFind("ab?c", "ac", .{ 0, 2 });
    try expectFind("ab?c", "abc", .{ 0, 3 });
    try expectFind("a.*c", "a123c", .{ 0, 5 });
}

test "regex: 锚点" {
    try expectFind("^abc", "abcx", .{ 0, 3 });
    try expectFind("^abc", "xabc", null);
    try expectFind("abc$", "xabc", .{ 1, 4 });
    try expectFind("abc$", "abcx", null);
}

test "regex: 字符类与转义" {
    try expectFind("[a-z]+[0-9]+", "xxab12yy", .{ 0, 6 });
    try expectFind("[^0-9]+", "12abc34", .{ 2, 5 });
    try expectFind("\\d+", "ab123cd", .{ 2, 5 });
    try expectFind("\\w+", "  fn main", .{ 2, 4 });
    try expectFind("\\s+", "ab   cd", .{ 2, 5 });
    try expectFind("a\\.c", "a.c", .{ 0, 3 });
    try expectFind("a\\.c", "abc", null);
    try expectFind("[.]", "1.5", .{ 1, 2 });
}

test "regex: 分组与选择" {
    try expectFind("(ab|cd)ef", "xxcdef", .{ 2, 6 });
    try expectFind("a(b|c)*d", "abcbcd", .{ 0, 6 });
    try expectFind("(a|b)+", "xxabayy", .{ 2, 5 });
    try expectFind("(fn|pub) ", "pub fn main", .{ 0, 4 });
}

test "regex: 中文与忽略大小写" {
    try expectFind("你好", "xx你好yy", .{ 2, 8 });
    try expectFind("fn\\s+main", "FN  MAIN", null);
    var re = try Regex.compile(testing.allocator, "fn\\s+main", .{ .ignore_case = true });
    defer re.deinit();
    try testing.expect(re.find("FN  MAIN") != null);
    try expectFind("fn\\s+main", "FN  MAIN", null);
}

test "regex: 贪婪回溯" {
    try expectFind("a.*b", "axbxb", .{ 0, 5 });
    try expectFind("(a+)+b", "aaab", .{ 0, 4 });
    try expectFind("(ab)+c", "ababc", .{ 0, 5 });
}

test "regex: 非法模式报错" {
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "[abc", .{}));
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "(ab", .{}));
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "a\\", .{}));
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "*a", .{}));
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "a|*", .{}));
}
