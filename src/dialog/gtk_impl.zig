const std = @import("std");

const gdk = @import("gdk");
const glib = @import("glib");
const gtk = @import("gtk");

const windy = @import("../windy.zig");

fn rgbaToGdk(color: windy.Rgba) gdk.RGBA {
    return .{
        .f_red = @as(f64, @floatFromInt(color.r)) / 255.0,
        .f_green = @as(f64, @floatFromInt(color.g)) / 255.0,
        .f_blue = @as(f64, @floatFromInt(color.b)) / 255.0,
        .f_alpha = @as(f64, @floatFromInt(color.a)) / 255.0,
    };
}

fn gdkToRgba(color: gdk.RGBA) windy.Rgba {
    return .{
        .r = @intFromFloat(color.f_red * 255.0),
        .g = @intFromFloat(color.f_green * 255.0),
        .b = @intFromFloat(color.f_blue * 255.0),
        .a = @intFromFloat(color.f_alpha * 255.0),
    };
}

fn appendFileFilters(dialog: *gtk.FileChooser, filters: []const windy.SentinelFilter) void {
    for (filters) |f| {
        const filter = gtk.FileFilter.new();
        filter.setName(f.name);
        if (f.exts) |exts| for (exts) |ext|
            filter.addPattern(ext);
        dialog.addFilter(filter);
    }
}

fn wait() void {
    while (gtk.eventsPending() != 0)
        _ = gtk.mainIteration();
}

pub fn openDialog(
    comptime multiple_selection: bool,
    _: std.mem.Allocator,
    child_allocator: std.mem.Allocator,
    dialog_type: windy.DialogType,
    filters: []const windy.SentinelFilter,
    title: [:0]const u8,
    default_path: ?[:0]const u8,
) !if (multiple_selection) []const []const u8 else []const u8 {
    var dummy: i32 = 0;
    if (gtk.initCheck(&dummy, null) == 0) return error.Initialization;

    const dialog = gtk.FileChooserDialog.new(
        title,
        null,
        if (dialog_type == .directory) .select_folder else .open,
        "_Cancel",
        @intFromEnum(gtk.ResponseType.cancel),
        "_Open",
        @intFromEnum(gtk.ResponseType.accept),
        @as(usize, 0),
    );
    defer {
        gtk.Widget.destroy(dialog.as(gtk.Widget));
        wait();
    }

    if (multiple_selection) gtk.FileChooser.setSelectMultiple(dialog.as(gtk.FileChooser), 1);
    if (default_path) |path| _ = gtk.FileChooser.setCurrentFolder(dialog.as(gtk.FileChooser), path);
    appendFileFilters(dialog.as(gtk.FileChooser), filters);

    if (gtk.Dialog.run(dialog.as(gtk.Dialog)) != @intFromEnum(gtk.ResponseType.accept))
        return &.{};

    if (!multiple_selection) {
        const path = gtk.FileChooser.getFilename(dialog.as(gtk.FileChooser)) orelse return &.{};
        defer glib.free(path);
        return child_allocator.dupe(u8, std.mem.span(path));
    }

    var ret: std.ArrayList([]const u8) = .empty;
    const file_list = gtk.FileChooser.getFilenames(dialog.as(gtk.FileChooser));
    defer glib.SList.free(file_list);

    var cur_list: ?*glib.SList = file_list;
    while (cur_list) |list| {
        defer cur_list = list.f_next;

        const data = list.f_data orelse continue;
        defer glib.free(data);

        const str: [*:0]const u8 = @ptrCast(data);
        try ret.append(child_allocator, try child_allocator.dupe(u8, std.mem.span(str)));
    }

    return try ret.toOwnedSlice(child_allocator);
}

pub fn saveDialog(
    _: std.mem.Allocator,
    child_allocator: std.mem.Allocator,
    filters: []const windy.SentinelFilter,
    title: [:0]const u8,
    default_path: ?[:0]const u8,
) ![]const u8 {
    var dummy: i32 = 0;
    if (gtk.initCheck(&dummy, null) == 0) return error.Initialization;

    const dialog = gtk.FileChooserDialog.new(
        title,
        null,
        .save,
        "_Cancel",
        @intFromEnum(gtk.ResponseType.cancel),
        "_Save",
        @intFromEnum(gtk.ResponseType.accept),
        @as(usize, 0),
    );
    defer {
        gtk.Widget.destroy(dialog.as(gtk.Widget));
        wait();
    }

    gtk.FileChooser.setDoOverwriteConfirmation(dialog.as(gtk.FileChooser), 1);
    if (default_path) |path| _ = gtk.FileChooser.setCurrentFolder(dialog.as(gtk.FileChooser), path);
    appendFileFilters(dialog.as(gtk.FileChooser), filters);

    if (gtk.Dialog.run(dialog.as(gtk.Dialog)) != @intFromEnum(gtk.ResponseType.accept))
        return &.{};

    const path = gtk.FileChooser.getFilename(dialog.as(gtk.FileChooser)) orelse return &.{};
    defer glib.free(path);
    return child_allocator.dupe(u8, std.mem.span(path));
}

pub fn message(
    _: std.mem.Allocator,
    level: windy.MessageLevel,
    buttons: windy.MessageButtons,
    text: [:0]const u8,
    title: [:0]const u8,
) !bool {
    var dummy: i32 = 0;
    if (gtk.initCheck(&dummy, null) == 0) return error.Initialization;

    const dialog = gtk.MessageDialog.new(
        null,
        .{ .modal = true, .destroy_with_parent = true },
        switch (level) {
            .info => .info,
            .warn => .warning,
            .err => .@"error",
        },
        switch (buttons) {
            .yes_no => .yes_no,
            .ok_cancel => .ok_cancel,
            .ok => .ok,
        },
        "%s",
        text.ptr,
    );
    defer {
        gtk.Widget.destroy(dialog.as(gtk.Widget));
        wait();
    }

    gtk.Window.setTitle(dialog.as(gtk.Window), title);

    const run_res = gtk.Dialog.run(dialog.as(gtk.Dialog));
    return run_res == @intFromEnum(gtk.ResponseType.ok) or run_res == @intFromEnum(gtk.ResponseType.yes);
}

pub fn colorChooser(
    _: std.mem.Allocator,
    color: windy.Rgba,
    use_alpha: bool,
    title: [:0]const u8,
) !windy.Rgba {
    var dummy: i32 = 0;
    if (gtk.initCheck(&dummy, null) == 0) return error.Initialization;

    const dialog = gtk.ColorChooserDialog.new(title, null);
    defer {
        gtk.Widget.destroy(dialog.as(gtk.Widget));
        wait();
    }

    gtk.ColorChooser.setUseAlpha(dialog.as(gtk.ColorChooser), @intFromBool(use_alpha));
    gtk.ColorChooser.setRgba(dialog.as(gtk.ColorChooser), &rgbaToGdk(color));

    if (gtk.Dialog.run(dialog.as(gtk.Dialog)) != @intFromEnum(gtk.ResponseType.ok))
        return error.Canceled;

    var gdk_color: gdk.RGBA = undefined;
    gtk.ColorChooser.getRgba(dialog.as(gtk.ColorChooser), &gdk_color);
    return gdkToRgba(gdk_color);
}
