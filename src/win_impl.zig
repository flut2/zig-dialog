const std = @import("std");

const win32 = @import("win32").everything;

const zd = @import("zd.zig");

fn appendFilters(allocator: std.mem.Allocator, dialog: *win32.IFileDialog, filters: []const zd.Filter) !void {
    const com_filters = try allocator.alloc(win32.COMDLG_FILTERSPEC, filters.len);
    for (filters, com_filters) |f, *cf| {
        var ext_list: std.ArrayList(u8) = .empty;
        if (f.exts) |exts| {
            for (exts, 0..) |ext, i|
                try ext_list.print(allocator, "*.{s}{s}", .{ ext, if (i == exts.len - 1) "" else ";" });
        } else try ext_list.appendSlice(allocator, "*.*");
        cf.* = .{
            .pszName = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, f.name),
            .pszSpec = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, ext_list.items),
        };
    }
    if (win32.FAILED(dialog.SetFileTypes(@intCast(com_filters.len), com_filters.ptr)))
        return error.FilterSetFailed;
}

fn setDefaultPath(allocator: std.mem.Allocator, dialog: *win32.IFileDialog, path: []const u8) !void {
    const w_path = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
    var folder: *win32.IShellItem = undefined;
    const path_res = win32.SHCreateItemFromParsingName(w_path, null, win32.IID_IShellItem, @ptrCast(&folder));
    if (path_res == HRESULT_FROM_WIN32(.ERROR_FILE_NOT_FOUND) or path_res == HRESULT_FROM_WIN32(.ERROR_INVALID_DRIVE))
        return;
    if (win32.FAILED(path_res)) return error.DefaultPathParseFailed;
    defer _ = folder.IUnknown.Release();

    if (win32.FAILED(dialog.SetFolder(folder))) return error.DefaultPathSetFailed;
}

pub fn openDialog(
    comptime multiple_selection: bool,
    allocator: std.mem.Allocator,
    child_allocator: std.mem.Allocator,
    dialog_type: zd.DialogType,
    filters: []const zd.Filter,
    title: []const u8,
    default_path: ?[]const u8,
) !if (multiple_selection) []const []const u8 else []const u8 {
    const init_res = win32.CoInitializeEx(null, .{ .APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1 });
    if (init_res != win32.RPC_E_CHANGED_MODE and win32.FAILED(init_res))
        return error.ComInitFailed;
    defer if (win32.SUCCEEDED(init_res)) win32.CoUninitialize();

    var dialog: *win32.IFileOpenDialog = undefined;
    if (win32.FAILED(win32.CoCreateInstance(
        win32.CLSID_FileOpenDialog,
        null,
        win32.CLSCTX_ALL,
        win32.IID_IFileOpenDialog,
        @ptrCast(&dialog),
    ))) return error.DialogInitFailed;
    defer _ = dialog.IUnknown.Release();

    if (multiple_selection or dialog_type == .directory) {
        var flags: win32.FILEOPENDIALOGOPTIONS = undefined;
        if (win32.FAILED(dialog.IFileDialog.GetOptions(@ptrCast(&flags))))
            return error.GetFlagsFailed;
        if (multiple_selection) flags.ALLOWMULTISELECT = 1;
        if (dialog_type == .directory) flags.PICKFOLDERS = 1;
        if (win32.FAILED(dialog.IFileDialog.SetOptions(flags)))
            return error.SetFlagsFailed;
    }

    try appendFilters(allocator, &dialog.IFileDialog, filters);
    if (default_path) |path| try setDefaultPath(allocator, &dialog.IFileDialog, path);
    if (win32.FAILED(dialog.IFileDialog.SetTitle(try std.unicode.wtf8ToWtf16LeAllocZ(allocator, title))))
        return error.SetTitleFailed;

    const show_res = dialog.IModalWindow.Show(null);
    if (show_res == HRESULT_FROM_WIN32(.ERROR_CANCELLED)) return &.{};
    if (win32.FAILED(show_res))
        return error.ShowDialogFailed;

    if (!multiple_selection) {
        var item: *win32.IShellItem = undefined;
        if (win32.FAILED(dialog.IFileDialog.GetResult(@ptrCast(&item))))
            return error.GetDialogResultFailed;
        defer _ = item.IUnknown.Release();

        var file_path: [*:0]u16 = undefined;
        if (win32.FAILED(item.GetDisplayName(win32.SIGDN_FILESYSPATH, @ptrCast(&file_path))))
            return error.GetDialogNameFailed;
        defer win32.CoTaskMemFree(file_path);

        return try std.unicode.wtf16LeToWtf8Alloc(child_allocator, std.mem.span(file_path));
    }

    var items: *win32.IShellItemArray = undefined;
    if (win32.FAILED(dialog.GetResults(@ptrCast(&items))))
        return error.GetDialogResultFailed;
    defer _ = items.IUnknown.Release();

    var items_len: u32 = 0;
    if (win32.FAILED(items.GetCount(@ptrCast(&items_len))))
        return error.GetPathLenFailed;
    if (items_len == 0) return &.{};

    var ret: std.ArrayList([]const u8) = .empty;
    for (0..items_len) |i| {
        var item: *win32.IShellItem = undefined;
        if (win32.FAILED(items.GetItemAt(@intCast(i), @ptrCast(&item))))
            return error.PathEnumerationFailed;

        const sfgao_fs = win32.SFGAO_FILESYSTEM;
        var attribs: u32 = undefined;
        if (win32.FAILED(item.GetAttributes(@intCast(sfgao_fs), @ptrCast(&attribs))) or (attribs & sfgao_fs) == 0)
            return error.PathAttribGetFailed;

        var path: [*:0]u16 = undefined;
        if (win32.FAILED(item.GetDisplayName(win32.SIGDN_FILESYSPATH, @ptrCast(&path))))
            return error.PathNameGetFailed;
        defer win32.CoTaskMemFree(path);

        try ret.append(child_allocator, try std.unicode.wtf16LeToWtf8Alloc(child_allocator, std.mem.span(path)));
    }

    return try ret.toOwnedSlice(child_allocator);
}

pub fn saveDialog(
    allocator: std.mem.Allocator,
    child_allocator: std.mem.Allocator,
    filters: []const zd.Filter,
    title: []const u8,
    default_path: ?[]const u8,
) ![]const u8 {
    const init_res = win32.CoInitializeEx(null, .{ .APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1 });
    if (init_res != win32.RPC_E_CHANGED_MODE and win32.FAILED(init_res))
        return error.ComInitFailed;
    defer if (win32.SUCCEEDED(init_res)) win32.CoUninitialize();

    var dialog: *win32.IFileSaveDialog = undefined;
    if (win32.FAILED(win32.CoCreateInstance(
        win32.CLSID_FileSaveDialog,
        null,
        win32.CLSCTX_ALL,
        win32.IID_IFileSaveDialog,
        @ptrCast(&dialog),
    ))) return error.DialogInitFailed;
    defer _ = dialog.IUnknown.Release();

    try appendFilters(allocator, &dialog.IFileDialog, filters);
    if (default_path) |path| try setDefaultPath(allocator, &dialog.IFileDialog, path);
    if (win32.FAILED(dialog.IFileDialog.SetTitle(try std.unicode.wtf8ToWtf16LeAllocZ(allocator, title))))
        return error.SetTitleFailed;

    const show_res = dialog.IModalWindow.Show(null);
    if (show_res == HRESULT_FROM_WIN32(.ERROR_CANCELLED)) return &.{};
    if (win32.FAILED(show_res))
        return error.ShowDialogFailed;

    var item: *win32.IShellItem = undefined;
    if (win32.FAILED(dialog.IFileDialog.GetResult(@ptrCast(&item))))
        return error.GetDialogResultFailed;
    defer _ = item.IUnknown.Release();

    var file_path: [*:0]u16 = undefined;
    if (win32.FAILED(item.GetDisplayName(win32.SIGDN_FILESYSPATH, @ptrCast(&file_path))))
        return error.GetDialogNameFailed;
    defer win32.CoTaskMemFree(file_path);

    return try std.unicode.wtf16LeToWtf8Alloc(child_allocator, std.mem.span(file_path));
}

pub fn message(
    allocator: std.mem.Allocator,
    level: zd.MessageLevel,
    buttons: zd.MessageButtons,
    text: []const u8,
    title: []const u8,
) !bool {
    var style: win32.MESSAGEBOX_STYLE = .{};
    switch (level) {
        .info => style.ICONASTERISK = 1,
        .warn => {
            style.ICONHAND = 1;
            style.ICONQUESTION = 1;
        },
        .err => style.ICONHAND = 1,
    }

    switch (buttons) {
        .yes_no => style.YESNO = 1,
        .ok_cancel => style.OKCANCEL = 1,
        .ok => {},
    }

    const res = win32.MessageBoxW(
        win32.GetActiveWindow(),
        try std.unicode.wtf8ToWtf16LeAllocZ(allocator, text),
        try std.unicode.wtf8ToWtf16LeAllocZ(allocator, title),
        style,
    );
    return res == .OK or res == .YES;
}

const UnsignedHRESULT = std.meta.Int(.unsigned, @typeInfo(win32.HRESULT).int.bits);
fn HRESULT_FROM_WIN32(err: win32.WIN32_ERROR) win32.HRESULT {
    const hr: UnsignedHRESULT = (@as(UnsignedHRESULT, @intFromEnum(err)) & 0x0000FFFF) |
        (@as(UnsignedHRESULT, @intFromEnum(win32.FACILITY_WIN32)) << 16) |
        @as(UnsignedHRESULT, 0x80000000);
    return @bitCast(hr);
}
