//! UTF-8 解码辅助：容错解码单个码点。
//!
//! 本项目多处需要"在字节偏移处解出一个码点并前进"（渲染折行、Markdown 解析、
//! 输入框光标移动、工具输出截断……）。此前每个模块各写一份实现（3 份完全相同 +
//! 若干子集变体），这里统一为单一实现，避免边界行为漂移。
//!
//! 容错约定（与 std 不同）：非法字节序列不报错，而是解出 U+FFFD 并只前进 1 字节，
//! 保证调用方的循环永远前进（避免死循环），也与渲染层"非法 UTF-8 不 panic"的策略一致。

const std = @import("std");

pub const Decoded = struct {
    /// 解出的码点（非法序列为 U+FFFD）
    cp: u21,
    /// 消耗的字节数（至少 1）
    len: usize,
};

/// 解码 `bytes[index]` 处的码点。调用方须保证 index < bytes.len。
///
/// 单字节情形直接返回该字节值（不校验合法性）——非法字节按 Latin-1 透传
/// （如 0xFF → U+00FF）。这是本项目多处既有行为（GBK 文件名等场景依赖它），
/// 与 std 的严格校验不同，务必保持。
pub fn decodeAt(bytes: []const u8, index: usize) Decoded {
    std.debug.assert(index < bytes.len);
    var len: usize = std.unicode.utf8ByteSequenceLength(bytes[index]) catch 1;
    if (index + len > bytes.len) len = 1;
    const cp: u21 = if (len == 1)
        bytes[index]
    else
        std.unicode.utf8Decode(bytes[index .. index + len]) catch 0xFFFD;
    return .{ .cp = cp, .len = len };
}

/// 编译期把字节串重复 n 次，返回指针（指向编译期常量；0.17 移除了 `x ** n` 数组重复运算符，
/// 且数组值到切片需显式 & ——返回指针可直接隐式转切片，调用点无需改）。
/// 实现注意（0.17 踩坑记录，三个失败方案都试过）：
///  - 循环里 comptime @memcpy 切片 = 解释器逐元素执行，100KB 要 60 秒+；
///  - 递归“返回 &局部” = 0.17 会编出部分损坏的常量（NUL 混入）；
///  - comptime @memset = 大量实例化时编译器确定性 OOM；
///  → 单字节走原生 @splat（快、无损坏、不吃内存），多字节实例都小（≤几 KB）走小循环。
pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    if (s.len == 1) {
        const a: [n]u8 = @splat(s[0]);
        return &a;
    }
    const out = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var o: [s.len * n]u8 = undefined;
        if (s.len == 0 or n == 0) break :blk o;
        var idx: usize = 0;
        while (idx < o.len) : (idx += s.len) @memcpy(o[idx..][0..s.len], s);
        break :blk o;
    };
    return &out;
}

/// 只算 `bytes[index]` 处码点的字节长度（不解码，用于只需前进的场景）。
/// 调用方须保证 index < bytes.len；返回至少 1。
pub fn nextLen(bytes: []const u8, index: usize) usize {
    const seq = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return 1;
    return @min(seq, bytes.len - index);
}

/// 从 index 处向前退一个码点的字节长度（用于 Backspace/左移光标）。
/// 返回值至少 1（不越过 index；index == 0 时返回 0）。
pub fn prevLen(bytes: []const u8, index: usize) usize {
    var i = index;
    while (i > 0) {
        i -= 1;
        if ((bytes[i] & 0xC0) != 0x80) break;
    }
    return index - i;
}

const testing = std.testing;

test "decodeAt：ASCII / 多字节 / 非法序列容错" {
    const ascii = "abc";
    try testing.expectEqual(Decoded{ .cp = 'a', .len = 1 }, decodeAt(ascii, 0));
    try testing.expectEqual(Decoded{ .cp = 'c', .len = 1 }, decodeAt(ascii, 2));

    const cjk = "中";
    try testing.expectEqual(Decoded{ .cp = 0x4E2D, .len = 3 }, decodeAt(cjk, 0));

    const emoji = "😀"; // U+1F600，4 字节
    try testing.expectEqual(Decoded{ .cp = 0x1F600, .len = 4 }, decodeAt(emoji, 0));

    // 非法单字节：按 Latin-1 透传（既有行为，见函数注释），前进 1 保证循环前进
    const bad = "\xFFabc";
    try testing.expectEqual(Decoded{ .cp = 0xFF, .len = 1 }, decodeAt(bad, 0));
    // 孤立续字节同样透传
    const stray = "\x80";
    try testing.expectEqual(Decoded{ .cp = 0x80, .len = 1 }, decodeAt(stray, 0));
    // 截断的多字节序列（首字节声称 3 字节但只剩 2）：退化为单字节透传
    const truncated = "中"[0..2];
    const t = decodeAt(truncated, 0);
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(@as(u21, 0xE4), t.cp);
    // 字节数足够但内容非法（UTF-8 非法延续字节）：cp 退化为 U+FFFD，
    // len 保持序列长度（原行为：catch 只改 cp 不改 len）
    const invalid_seq = "\xE4\x41\x42";
    try testing.expectEqual(Decoded{ .cp = 0xFFFD, .len = 3 }, decodeAt(invalid_seq, 0));
}

test "nextLen / prevLen：字节长度与回退" {
    const mixed = "a中😀";
    try testing.expectEqual(@as(usize, 1), nextLen(mixed, 0));
    try testing.expectEqual(@as(usize, 3), nextLen(mixed, 1));
    try testing.expectEqual(@as(usize, 4), nextLen(mixed, 4));

    // prevLen：从末尾回退
    try testing.expectEqual(@as(usize, 4), prevLen(mixed, 8));
    try testing.expectEqual(@as(usize, 3), prevLen(mixed, 4));
    try testing.expectEqual(@as(usize, 1), prevLen(mixed, 1));
    try testing.expectEqual(@as(usize, 0), prevLen(mixed, 0));

    // 截断序列的 prevLen 不会越界
    try testing.expectEqual(@as(usize, 1), prevLen("\x80", 1));
    // nextLen 对截断序列返回剩余长度
    try testing.expectEqual(@as(usize, 2), nextLen("中"[0..2], 0));
}
