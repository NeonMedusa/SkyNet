//! 系统剪贴板写入：Windows = Win32 CF_UNICODETEXT；
//! Linux = wl-copy / xclip / xsel 外部命令链；WSL 追加 powershell.exe 互操通道（无 Wayland/X11 工具时）。
//! 写失败返回 false（调用方决定提示），绝不 panic。
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;

extern "user32" fn OpenClipboard(hwnd: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) std.os.windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) std.os.windows.BOOL;
extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

/// 将 UTF-8 文本写入系统剪贴板，成功返回 true
pub fn setText(io: Io, allocator: Allocator, text: []const u8) bool {
    if (builtin.os.tag == .windows) return setTextWindows(allocator, text);
    return setTextPosix(io, text);
}

/// Windows：CF_UNICODETEXT（剪贴板可能被短暂占用，重试几次）
fn setTextWindows(allocator: Allocator, text: []const u8) bool {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return false;
    defer allocator.free(utf16);
    const byte_len = (utf16.len + 1) * @sizeOf(u16); // 含结尾 NUL

    var opened = false;
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        if (OpenClipboard(null).toBool()) {
            opened = true;
            break;
        }
    }
    if (!opened) return false;
    defer _ = CloseClipboard();

    if (!EmptyClipboard().toBool()) return false;

    const hmem = GlobalAlloc(GMEM_MOVEABLE, byte_len) orelse return false;
    const dst = GlobalLock(hmem) orelse {
        _ = GlobalFree(hmem);
        return false;
    };
    @memcpy(@as([*]u8, @ptrCast(dst))[0..byte_len], std.mem.sliceAsBytes(utf16[0 .. utf16.len + 1]));
    _ = GlobalUnlock(hmem);

    if (SetClipboardData(CF_UNICODETEXT, hmem) == null) {
        _ = GlobalFree(hmem);
        return false;
    }
    // 成功后所有权归系统剪贴板，不能再释放 hmem
    return true;
}

/// Linux：按可用性依次尝试 wl-copy（Wayland）/ xclip / xsel（X11）/ powershell.exe（WSL 互操作），stdin 喂入文本。
fn setTextPosix(io: Io, text: []const u8) bool {
    // WSL：无 Wayland/X11 剪贴板工具时的 Windows 互操作通道。
    // 必须取 stdin 原始字节再显式按 UTF-8 解码：直接管道会被控制台代码页转码（clip.exe 中文必乱码）。
    const ps_script =
        "$in=[Console]::OpenStandardInput();" ++
        "$ms=New-Object IO.MemoryStream;" ++
        "$in.CopyTo($ms);" ++
        "$txt=[Text.Encoding]::UTF8.GetString($ms.ToArray());" ++
        "Set-Clipboard -Value $txt";
    const candidates = [_][]const []const u8{
        &.{ "wl-copy" },
        &.{ "xclip", "-selection", "clipboard" },
        &.{ "xsel", "--input", "--clipboard" },
        &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps_script },
    };
    for (candidates) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue; // 命令不存在 → 试下一个
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(io, text) catch {};
            stdin.close(io);
            // 已手动关闭 stdin，置空避免 Child.wait 清理阶段二次 close（std 0.17 将 EBADF 视为 ABA/use-after-free，debug 下 unreachable  panic）
            child.stdin = null;
        }
        const term = child.wait(io) catch {
            // 未成功回收 → 才有资格 kill；wait 之后不能再 kill（std 不清 child.id，pid 可能已被复用）
            child.kill(io);
            continue;
        };
        switch (term) {
            .exited => |code| if (code == 0) return true,
            else => {},
        }
    }
    return false;
}
