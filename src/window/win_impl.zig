const std = @import("std");
const L = std.unicode.wtf8ToWtf16LeStringLiteral;

const win32 = @import("win32").everything;

const windy = @import("../windy.zig");

var main_class: u16 = 0;
var clipboard_class: u16 = 0;
var win32_inst: win32.HINSTANCE = undefined;

pub fn init() !void {
    const init_res = win32.CoInitializeEx(null, .{ .APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1 });
    if (init_res != win32.RPC_E_CHANGED_MODE and win32.FAILED(init_res)) {
        printError();
        return error.ComInit;
    }

    win32_inst = win32.GetModuleHandleW(null) orelse {
        printError();
        return error.Instance;
    };

    var wc = std.mem.zeroes(win32.WNDCLASSW);
    wc.style = .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 };
    wc.lpfnWndProc = windowProc;
    wc.hInstance = win32_inst;
    wc.lpszClassName = L("Windy Class");
    wc.hCursor = win32.LoadCursorW(null, win32.IDC_ARROW);
    wc.hIcon = @ptrCast(win32.LoadImageW(
        win32_inst,
        L("WINDY_ICON"),
        win32.IMAGE_ICON,
        0,
        0,
        .{ .DEFAULTSIZE = 1, .SHARED = 1 },
    ) orelse win32.LoadImageW(
        null,
        win32.IDI_APPLICATION,
        win32.IMAGE_ICON,
        0,
        0,
        .{ .DEFAULTSIZE = 1, .SHARED = 1 },
    ) orelse {
        printError();
        return error.WindowIcon;
    });

    main_class = win32.RegisterClassW(&wc);
    if (main_class == 0) {
        printError();
        return error.MainClass;
    }

    var wc_clip = std.mem.zeroes(win32.WNDCLASSEXW);
    wc_clip.cbSize = @sizeOf(win32.WNDCLASSEXW);
    wc_clip.style = .{ .OWNDC = 1 };
    wc_clip.lpfnWndProc = win32.DefWindowProcW;
    wc_clip.hInstance = win32_inst;
    wc_clip.lpszClassName = L("Windy Clipboard Class");

    clipboard_class = win32.RegisterClassExW(&wc_clip);
    if (clipboard_class == 0) {
        printError();
        return error.ClipboardClass;
    }
}

pub fn deinit() void {
    win32.CoUninitialize();
}

pub fn createWindow(allocator: std.mem.Allocator, w: u16, h: u16, opts: windy.Window.Options) !windy.Window {
    const wide_title = if (opts.title) |t| try std.unicode.wtf8ToWtf16LeAllocZ(allocator, t) else L("Windy Window");
    defer if (opts.title != null) allocator.free(wide_title);

    const start_pos: windy.Position = opts.start_pos orelse .{ .x = 0, .y = 0 };

    const style = win32.WS_OVERLAPPEDWINDOW;
    const ex_style: win32.WINDOW_EX_STYLE = .{};

    const hwnd = win32.CreateWindowExW(
        ex_style,
        makeIntAtom(main_class),
        wide_title,
        style,
        start_pos.x,
        start_pos.y,
        w,
        h,
        null,
        null,
        win32_inst,
        null,
    ) orelse {
        printError();
        return error.Window;
    };

    _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);

    return .{ .id = @intFromPtr(hwnd), .platform = .{ .style = style, .ex_style = ex_style } };
}

pub fn destroyWindow(wind: windy.Window) void {
    _ = win32.DestroyWindow(@ptrFromInt(wind.id));
}

pub fn clipboardWindow() !windy.Window {
    const style: win32.WINDOW_STYLE = .{ .CLIPSIBLINGS = 1, .CLIPCHILDREN = 1 };
    const ex_style = win32.WS_EX_OVERLAPPEDWINDOW;

    const hwnd = win32.CreateWindowExW(
        ex_style,
        makeIntAtom(clipboard_class),
        L("Windy Clipboard Window"),
        style,
        0,
        0,
        1,
        1,
        null,
        null,
        win32_inst,
        null,
    ) orelse {
        printError();
        return error.Window;
    };

    return .{ .id = @intFromPtr(hwnd), .platform = .{ .style = style, .ex_style = ex_style } };
}

pub fn setTitle(allocator: std.mem.Allocator, wid: windy.Window.Id, title: [:0]const u8) !void {
    const wide_title = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, title);
    defer allocator.free(wide_title);
    _ = win32.SetWindowTextW(@ptrFromInt(wid), wide_title);
}

pub fn setCursor(wind: *windy.Window, cursor: windy.Cursor) !void {
    wind.platform.cursor = cursor;
    _ = win32.SetCursor(@ptrFromInt(cursor.id));
}

pub fn setMinWindowSize(wind: *windy.Window, min_size: windy.Size) !void {
    _ = wind; // autofix
    _ = min_size; // autofix
}

pub fn setMaxWindowSize(wind: *windy.Window, max_size: windy.Size) !void {
    _ = wind; // autofix
    _ = max_size; // autofix
}

pub fn setWindowResizeIncr(wind: *windy.Window, incr_size: windy.Size) !void {
    _ = wind; // autofix
    _ = incr_size; // autofix
}

pub fn setWindowAspect(wind: *windy.Window, numerator: u16, denominator: u16) !void {
    _ = wind; // autofix
    _ = numerator; // autofix
    _ = denominator; // autofix
}

pub fn resize(wind: *windy.Window, size: windy.Size) !void {
    _ = wind; // autofix
    _ = size; // autofix
}

pub fn move(wind: *windy.Window, pos: windy.Position) !void {
    _ = wind; // autofix
    _ = pos; // autofix
}

pub fn getClipboard() ![]const u8 {
    var fba: std.heap.FixedBufferAllocator = .init(windy.clipboard_buffer);
    const allocator = fba.allocator();

    var tries: usize = 0;
    while (win32.OpenClipboard(@ptrFromInt(windy.clipboard_window.id)) == 0) : (tries += 1) {
        if (tries == 5) return error.ClipboardLocked;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    defer _ = win32.CloseClipboard();

    const obj: isize = @intCast(@intFromPtr(win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse {
        if (win32.GetLastError() == .ERROR_NOT_FOUND) return &.{};
        printError();
        return error.ClipboardGet;
    }));

    const lock = win32.GlobalLock(obj) orelse {
        if (win32.GetLastError() == .ERROR_DISCARDED) return &.{};
        printError();
        return error.Lock;
    };
    defer _ = win32.GlobalUnlock(obj);

    const text: [*:0]const u16 = @ptrCast(@alignCast(lock));
    return std.unicode.wtf16LeToWtf8Alloc(allocator, std.mem.span(text)) catch error.OutOfMemory;
}

pub fn setClipboard(new_buf: []const u8) !void {
    if (new_buf.len == 0) {
        var tries: usize = 0;
        while (win32.OpenClipboard(@ptrFromInt(windy.clipboard_window.id)) == 0) : (tries += 1) {
            if (tries == 5) return error.ClipboardLocked;
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }
        _ = win32.EmptyClipboard();
        return;
    }

    var fba: std.heap.FixedBufferAllocator = .init(windy.clipboard_buffer);
    const allocator = fba.allocator();

    const wide_text = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, new_buf);

    const obj = win32.GlobalAlloc(win32.GMEM_MOVEABLE, wide_text.len * @sizeOf(u16));
    if (obj == 0) {
        printError();
        return error.OutOfMemory;
    }
    errdefer _ = win32.GlobalFree(obj);

    const lock = win32.GlobalLock(obj) orelse {
        printError();
        return error.Lock;
    };
    const buffer: [*]u16 = @ptrCast(@alignCast(lock));
    @memcpy(buffer, wide_text);
    _ = win32.GlobalUnlock(obj);

    var tries: usize = 0;
    while (win32.OpenClipboard(@ptrFromInt(windy.clipboard_window.id)) == 0) : (tries += 1) {
        if (tries == 5) return error.ClipboardLocked;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    _ = win32.EmptyClipboard();
    if (win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), buffer) == null) {
        printError();
        return error.ClipboardSet;
    }
    _ = win32.CloseClipboard();
}

pub fn pollEvents() !void {
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

pub fn waitEvent() !void {
    _ = win32.MsgWaitForMultipleObjects(0, null, win32.FALSE, win32.INFINITE, win32.QS_ALLINPUT);
}

pub fn createSurface(comptime vk: type, wind: windy.Window, inst: vk.InstanceProxy) !vk.SurfaceKHR {
    const sci: vk.Win32SurfaceCreateInfoKHR = .{
        .hinstance = win32_inst,
        .hwnd = @ptrFromInt(wind.id),
    };
    return try inst.createWin32SurfaceKHR(&sci, null);
}

pub fn vulkanExts() []const [*:0]const u8 {
    return &.{ "VK_KHR_surface", "VK_KHR_win32_surface" };
}

pub fn createCursor(argb_raw_img: []const u8, w: u16, h: u16, x_hot: u16, y_hot: u16) !windy.Cursor {
    return .{ .id = @intFromPtr(try icon(argb_raw_img, w, h, x_hot, y_hot, false)) };
}

pub fn destroyCursor(cursor: windy.Cursor) void {
    _ = win32.DestroyIcon(@ptrFromInt(cursor.id));
}

fn icon(argb_raw_img: []const u8, w: u16, h: u16, x_hot: u16, y_hot: u16, is_icon: bool) !win32.HICON {
    var bmp_header = std.mem.zeroes(win32.BITMAPV5HEADER);
    bmp_header.bV5Size = @sizeOf(win32.BITMAPV5HEADER);
    bmp_header.bV5Width = w;
    // must be negative h to make the image top-down
    bmp_header.bV5Height = -@as(i32, h);
    bmp_header.bV5Planes = 1;
    bmp_header.bV5BitCount = @bitSizeOf(i32);
    bmp_header.bV5Compression = win32.BI_BITFIELDS;
    bmp_header.bV5AlphaMask = 0xff000000;
    bmp_header.bV5RedMask = 0xff0000;
    bmp_header.bV5GreenMask = 0xff00;
    bmp_header.bV5BlueMask = 0xff;

    const dv_ctx = win32.GetDC(null) orelse {
        printError();
        return error.DeviceContext;
    };
    defer _ = win32.ReleaseDC(null, dv_ctx);

    var out_px: [*]u8 = undefined;
    const color = win32.CreateDIBSection(dv_ctx, @ptrCast(&bmp_header), win32.DIB_RGB_COLORS, @ptrCast(&out_px), null, 0) orelse {
        printError();
        return error.DibSection;
    };
    defer _ = win32.DeleteObject(color);
    @memcpy(out_px[0 .. w * h * 4], argb_raw_img);

    const mask = win32.CreateBitmap(w, h, 1, 1, null) orelse {
        printError();
        return error.IconMask;
    };
    defer _ = win32.DeleteObject(mask);

    var icon_info: win32.ICONINFO = .{
        .fIcon = @intFromBool(is_icon),
        .xHotspot = x_hot,
        .yHotspot = y_hot,
        .hbmMask = mask,
        .hbmColor = color,
    };

    return win32.CreateIconIndirect(&icon_info) orelse {
        printError();
        return error.IconCreate;
    };
}

fn windowProc(hwnd: win32.HWND, msg: u32, wp: win32.WPARAM, lp: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    const wind = windy.window_map.getPtr(@intFromPtr(hwnd)) orelse
        return win32.DefWindowProcW(hwnd, msg, wp, lp);

    process: switch (msg) {
        win32.WM_CLOSE, win32.WM_QUIT => {
            wind.should_close = true;
            return 0;
        },
        win32.WM_SYSCOMMAND => switch (wp & 0xFFF0) {
            win32.SC_CLOSE => {
                wind.should_close = true;
                return win32.TRUE;
            },
            else => {},
        },
        win32.WM_SETCURSOR => if (wordLower(lp) == win32.HTCLIENT) if (wind.platform.cursor) |cursor| {
            setCursor(wind, cursor) catch break :process;
            return win32.TRUE;
        },
        win32.WM_PAINT => if (wind.callbacks.refresh) |cb| cb(wind),
        win32.WM_SIZE => {
            const w = wordLower(lp);
            const h = wordHigher(lp);
            if (wind.size.w != w or wind.size.h != h) {
                wind.size = .{ .w = w, .h = h };
                if (wind.callbacks.resize) |cb| cb(wind, w, h);
            }
            return 0;
        },
        win32.WM_MOVE => {
            const x = lpX(lp);
            const y = lpY(lp);
            if (wind.pos.x != x or wind.pos.y != y) {
                wind.pos = .{ .x = x, .y = y };
                if (wind.callbacks.move) |cb| cb(wind, x, y);
            }
            return 0;
        },
        win32.WM_LBUTTONDOWN => if (wind.callbacks.mouse) |cb| {
            cb(wind, .press, .left, lpX(lp), lpY(lp), wind.platform.mods);
            return 0;
        },
        win32.WM_LBUTTONUP => if (wind.callbacks.mouse) |cb| {
            cb(wind, .release, .left, lpX(lp), lpY(lp), wind.platform.mods);
            return 0;
        },
        win32.WM_MBUTTONDOWN => if (wind.callbacks.mouse) |cb| {
            cb(wind, .press, .middle, lpX(lp), lpY(lp), wind.platform.mods);
            return 0;
        },
        win32.WM_MBUTTONUP => if (wind.callbacks.mouse) |cb| {
            cb(wind, .release, .middle, lpX(lp), lpY(lp), wind.platform.mods);
            return 0;
        },
        win32.WM_RBUTTONDOWN => if (wind.callbacks.mouse) |cb| {
            cb(wind, .press, .right, lpX(lp), lpY(lp), wind.platform.mods);
            return 0;
        },
        win32.WM_RBUTTONUP => if (wind.callbacks.mouse) |cb| {
            cb(wind, .release, .right, lpX(lp), lpY(lp), wind.platform.mods);
            return 0;
        },
        win32.WM_XBUTTONDOWN => if (wind.callbacks.mouse) |cb| {
            cb(wind, .press, switch (wordHigher(wp)) {
                @as(u32, @bitCast(win32.XBUTTON1)) => .m4,
                @as(u32, @bitCast(win32.XBUTTON2)) => .m5,
                else => |m| {
                    std.log.err("Invalid mouse button received: {}", .{m});
                    break :process;
                },
            }, lpX(lp), lpY(lp), wind.platform.mods);
            return win32.TRUE;
        },
        win32.WM_XBUTTONUP => if (wind.callbacks.mouse) |cb| {
            cb(wind, .release, switch (wordHigher(wp)) {
                @as(u32, @bitCast(win32.XBUTTON1)) => .m4,
                @as(u32, @bitCast(win32.XBUTTON2)) => .m5,
                else => |m| {
                    std.log.err("Invalid mouse button received: {}", .{m});
                    break :process;
                },
            }, lpX(lp), lpY(lp), wind.platform.mods);
            return win32.TRUE;
        },
        win32.WM_MOUSEMOVE => if (wind.callbacks.mouseMove) |cb| {
            cb(wind, shortLower(lp), shortHigher(lp), wind.platform.mods);
            return 0;
        },
        win32.WM_MOUSEWHEEL => if (wind.callbacks.scroll) |cb| {
            const delta: f32 = @floatFromInt(shortHigher(wp));
            cb(wind, delta / win32.WHEEL_DELTA, 0, wind.platform.mods);
            return 0;
        },
        win32.WM_MOUSEHWHEEL => if (wind.callbacks.scroll) |cb| {
            const delta: f32 = @floatFromInt(shortHigher(wp));
            cb(wind, 0, delta / win32.WHEEL_DELTA, wind.platform.mods);
            return 0;
        },
        win32.WM_CHAR, win32.WM_SYSCHAR => if (wind.callbacks.char) |cb| {
            const char: u16 = @intCast(wp);
            if (wind.platform.surrogate != 0) {
                cb(
                    wind,
                    std.unicode.utf16DecodeSurrogatePair(&.{ wind.platform.surrogate, char }) catch break :process,
                    wind.platform.mods,
                );
                wind.platform.surrogate = 0;
                return 0;
            } else if (std.unicode.utf16IsLowSurrogate(char) or std.unicode.utf16IsHighSurrogate(char)) {
                wind.platform.surrogate = char;
                return 0;
            }

            cb(wind, char, wind.platform.mods);
            return 0;
        },
        win32.WM_UNICHAR => {
            // announce support either way, char cb could be registered later
            if (wp == win32.UNICODE_NOCHAR) return win32.TRUE;
            if (wind.callbacks.char) |cb| {
                cb(wind, @intCast(wp), wind.platform.mods);
                return 0;
            }
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            if (wp == @intFromEnum(win32.VK_PROCESSKEY)) return 0;

            const state: windy.PressState = if (wordHigher(lp) & win32.KF_UP != 0) .release else .press;
            switch (wp) {
                @intFromEnum(win32.VK_SHIFT) => wind.platform.mods.shift = state == .press,
                @intFromEnum(win32.VK_CAPITAL) => {
                    if (state == .press) wind.platform.mods.caps_lock = !wind.platform.mods.caps_lock;
                },
                @intFromEnum(win32.VK_CONTROL) => wind.platform.mods.ctrl = state == .press,
                @intFromEnum(win32.VK_MENU) => wind.platform.mods.alt = state == .press,
                @intFromEnum(win32.VK_NUMLOCK) => {
                    if (state == .press) wind.platform.mods.num_lock = !wind.platform.mods.num_lock;
                },
                @intFromEnum(win32.VK_LWIN), @intFromEnum(win32.VK_RWIN) => wind.platform.mods.super = state == .press,
                else => {},
            }

            const cb = wind.callbacks.key orelse return 0;

            var scancode = (wordHigher(lp) & (win32.KF_EXTENDED | 0xFF));
            if (scancode == 0) scancode = win32.MapVirtualKeyW(@intCast(wp), win32.MAPVK_VK_TO_VSC);
            cb(wind, state, scancodeToKey(scancode), wind.platform.mods);
        },
        else => {},
    }

    return win32.DefWindowProcW(hwnd, msg, wp, lp);
}

fn printError() void {
    std.log.err("Win32 error: {f}", .{win32.GetLastError()});
}

fn scancodeToKey(scancode: u32) windy.Key {
    return switch (scancode) {
        0x00B => .zero,
        0x002 => .one,
        0x003 => .two,
        0x004 => .three,
        0x005 => .four,
        0x006 => .five,
        0x007 => .six,
        0x008 => .seven,
        0x009 => .eight,
        0x00A => .nine,
        0x01E => .a,
        0x030 => .b,
        0x02E => .c,
        0x020 => .d,
        0x012 => .e,
        0x021 => .f,
        0x022 => .g,
        0x023 => .h,
        0x017 => .i,
        0x024 => .j,
        0x025 => .k,
        0x026 => .l,
        0x032 => .m,
        0x031 => .n,
        0x018 => .o,
        0x019 => .p,
        0x010 => .q,
        0x013 => .r,
        0x01F => .s,
        0x014 => .t,
        0x016 => .u,
        0x02F => .v,
        0x011 => .w,
        0x02D => .x,
        0x015 => .y,
        0x02C => .z,
        0x028 => .apostrophe,
        0x02B => .backslash,
        0x033 => .comma,
        0x00D => .equal,
        0x029 => .grave_accent,
        0x01A => .left_bracket,
        0x00C => .minus,
        0x034 => .period,
        0x01B => .right_bracket,
        0x027 => .semicolon,
        0x035 => .slash,
        0x00E => .backspace,
        0x153 => .delete,
        0x14F => .end,
        0x01C => .enter,
        0x001 => .escape,
        0x147 => .home,
        0x152 => .insert,
        0x15D => .menu,
        0x151 => .page_down,
        0x149 => .page_up,
        0x045 => .pause,
        0x039 => .space,
        0x00F => .tab,
        0x03A => .caps_lock,
        0x145 => .num_lock,
        0x046 => .scroll_lock,
        0x03B => .f1,
        0x03C => .f2,
        0x03D => .f3,
        0x03E => .f4,
        0x03F => .f5,
        0x040 => .f6,
        0x041 => .f7,
        0x042 => .f8,
        0x043 => .f9,
        0x044 => .f10,
        0x057 => .f11,
        0x058 => .f12,
        0x064 => .f13,
        0x065 => .f14,
        0x066 => .f15,
        0x067 => .f16,
        0x068 => .f17,
        0x069 => .f18,
        0x06A => .f19,
        0x06B => .f20,
        0x06C => .f21,
        0x06D => .f22,
        0x06E => .f23,
        0x076 => .f24,
        0x038 => .left_alt,
        0x01D => .left_control,
        0x02A => .left_shift,
        0x15B => .left_super,
        0x137 => .print,
        0x138 => .right_alt,
        0x11D => .right_control,
        0x036 => .right_shift,
        0x15C => .right_super,
        0x150 => .down,
        0x14B => .left,
        0x14D => .right,
        0x148 => .up,
        0x052 => .kp_0,
        0x04F => .kp_1,
        0x050 => .kp_2,
        0x051 => .kp_3,
        0x04B => .kp_4,
        0x04C => .kp_5,
        0x04D => .kp_6,
        0x047 => .kp_7,
        0x048 => .kp_8,
        0x049 => .kp_9,
        0x04E => .kp_add,
        0x053 => .kp_decimal,
        0x135 => .kp_divide,
        0x11C => .kp_enter,
        0x059 => .kp_equal,
        0x037 => .kp_multiply,
        0x04A => .kp_subtract,
        else => .invalid,
    };
}

/// Equivalent of win32's `LOWORD`.
fn wordLower(x: anytype) u16 {
    return @intCast(x & 0xFFFF);
}

/// Equivalent of win32's `HIWORD`.
fn wordHigher(x: anytype) u16 {
    return @intCast((x >> 16) & 0xFFFF);
}

/// Equivalent of win32's `LOSHORT`.
fn shortLower(x: anytype) i16 {
    return @bitCast(wordLower(x));
}

/// Equivalent of win32's `HISHORT`.
fn shortHigher(x: anytype) i16 {
    return @bitCast(wordHigher(x));
}

/// Equivalent of win32's `GET_X_LPARAM`.
fn lpX(lParam: win32.LPARAM) i16 {
    return @intCast(lParam & 0xFFFF);
}

/// Equivalent of win32's `GET_Y_LPARAM`.
fn lpY(lParam: win32.LPARAM) i16 {
    return @intCast(lParam >> 16 & 0xFFFF);
}

/// Equivalent of win32's `MAKEINTATOM`.
inline fn makeIntAtom(atom: u16) ?[*:0]align(1) const u16 {
    return @ptrFromInt(atom);
}
