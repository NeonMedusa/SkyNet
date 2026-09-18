const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;

extern "user32" fn OpenClipboard(hwnd: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

/// 将 UTF-8 文本写入 Windows 剪贴板（CF_UNICODETEXT），成功返回 true
pub fn setText(allocator: Allocator, text: []const u8) bool {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return false;
    defer allocator.free(utf16);
    const byte_len = (utf16.len + 1) * @sizeOf(u16); // 含结尾 NUL

    // 剪贴板可能被其他进程短暂占用，重试几次
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
