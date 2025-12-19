const std = @import("std");
const builtin = @import("builtin");

const options = @import("options");

const gtk = @import("gtk_impl.zig");
const win = @import("win_impl.zig");
const zenity = @import("zenity_impl.zig");

pub const MessageLevel = enum { info, warn, err };
pub const MessageButtons = enum { yes_no, ok_cancel, ok };
pub const DialogType = enum { file, directory };
pub const Filter = struct {
    name: []const u8,
    /// Null implies all extensions
    exts: ?[]const []const u8 = null,
};

pub const SentinelFilter = struct {
    name: [:0]const u8,
    exts: ?[]const [:0]const u8 = null,

    fn deinit(self: SentinelFilter, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.exts) |e| {
            for (e) |ext| allocator.free(ext);
            allocator.free(e);
        }
    }
};

const ModParams = struct {
    title: []const u8,
    default_path: ?[]const u8,
    filters: []const Filter,
};

const ModParamsSentinel = struct {
    title: [:0]const u8,
    default_path: ?[:0]const u8,
    filters: []const SentinelFilter,
};

fn transformFilters(allocator: std.mem.Allocator, filters: []const Filter) ![]const SentinelFilter {
    var new_filters: std.ArrayList(SentinelFilter) = .empty;
    for (filters) |f| {
        var new_exts: std.ArrayList([:0]const u8) = .empty;
        if (f.exts) |exts| for (exts) |ext|
            try new_exts.append(allocator, try std.fmt.allocPrintSentinel(allocator, "*.{s}", .{ext}, 0));
        try new_filters.append(allocator, .{
            .name = try allocator.dupeZ(u8, f.name),
            .exts = if (new_exts.items.len == 0) null else try new_exts.toOwnedSlice(allocator),
        });
    }
    return try new_filters.toOwnedSlice(allocator);
}

fn isLinuxOrBsd() bool {
    return builtin.os.tag == .linux or builtin.os.tag.isBSD();
}

fn modParams(
    comptime requires_sentinel: bool,
    allocator: std.mem.Allocator,
    title: []const u8,
    default_path: ?[]const u8,
    filters: []const Filter,
) !if (requires_sentinel) ModParamsSentinel else ModParams {
    if (!requires_sentinel) return .{
        .title = title,
        .default_path = default_path,
        .filters = filters,
    };

    return .{
        .title = if (requires_sentinel)
            try std.fmt.allocPrintSentinel(allocator, "{s}", .{title}, 0)
        else
            title,
        .default_path = if (default_path) |path| b: {
            break :b if (requires_sentinel)
                try std.fmt.allocPrintSentinel(allocator, "{s}", .{path}, 0)
            else
                path;
        } else null,
        .filters = if (requires_sentinel)
            try transformFilters(allocator, filters)
        else
            filters,
    };
}

/// Frees the results of `openDialog()`, `multiOpenDialog()` and `saveDialog()`.
/// This is just a convenience function that does not do anything special,
/// it just frees the root slice and its child slices, if any.
pub fn freeResult(allocator: std.mem.Allocator, result: anytype) void {
    switch (@TypeOf(result)) {
        []const u8 => allocator.free(result),
        []const []const u8 => {
            for (result) |val| allocator.free(val);
            allocator.free(result);
        },
        else => |T| @compileError("Invalid type given to `freeResult()`: " ++ @typeName(T)),
    }
}

/// Opens an open dialog of the given type, returns the resulting path
/// once the user is finished interacting with it.
/// Note: Windows assumes input strings to be WTF8 and returns WTF8.
pub fn openDialog(
    comptime multiple_selection: bool,
    allocator: std.mem.Allocator,
    dialog_type: DialogType,
    filters: []const Filter,
    /// The title will be set to `Select Folder(s)` or `Select File(s)`
    /// (depending on `dialog_type` and `multiple_selection`) if set to null
    title: ?[]const u8,
    default_path: ?[]const u8,
) !if (multiple_selection) []const []const u8 else []const u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const requires_sentinel = comptime isLinuxOrBsd() and options.use_gtk;

    const unwrapped_title = title orelse switch (dialog_type) {
        .directory => "Select Folder" ++ if (multiple_selection) "s" else "",
        .file => "Select File" ++ if (multiple_selection) "s" else "",
    };
    const mod = try modParams(requires_sentinel, arena_allocator, unwrapped_title, default_path, filters);

    if (comptime isLinuxOrBsd()) {
        return if (options.use_gtk)
            try gtk.openDialog(multiple_selection, allocator, dialog_type, mod.filters, mod.title, mod.default_path)
        else
            try zenity.openDialog(multiple_selection, arena_allocator, allocator, dialog_type, mod.filters, mod.title, mod.default_path);
    }

    return switch (builtin.os.tag) {
        .windows => win.openDialog(multiple_selection, arena_allocator, allocator, dialog_type, mod.filters, mod.title, mod.default_path),
        else => @compileError("Unsupported OS"),
    };
}

/// Opens a save dialog of the given type, returns the resulting path
/// once the user is finished interacting with it.
/// Note: Windows assumes input strings to be WTF8 and returns WTF8.
pub fn saveDialog(
    allocator: std.mem.Allocator,
    filters: []const Filter,
    /// The title will be set to `Save File` if set to null
    title: ?[]const u8,
    default_path: ?[]const u8,
) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const requires_sentinel = comptime isLinuxOrBsd() and options.use_gtk;

    const unwrapped_title = title orelse "Save File";
    const mod = try modParams(requires_sentinel, arena_allocator, unwrapped_title, default_path, filters);

    if (comptime isLinuxOrBsd()) {
        return if (options.use_gtk)
            try gtk.saveDialog(allocator, mod.filters, mod.title, mod.default_path)
        else
            try zenity.saveDialog(arena_allocator, allocator, mod.filters, mod.title, mod.default_path);
    }

    return switch (builtin.os.tag) {
        .windows => try win.saveDialog(arena_allocator, allocator, mod.filters, mod.title, mod.default_path),
        else => @compileError("Unsupported OS"),
    };
}

/// Opens a message box of the given level.
/// Returns true if execution was successful and either `Ok` or `Yes` were clicked.
/// Note: Windows assumes input strings to be WTF8.
pub fn message(
    allocator: std.mem.Allocator,
    level: MessageLevel,
    buttons: MessageButtons,
    text: []const u8,
    /// The title will be set to `Info`, `Warning` or `Error` if set to null,
    /// depending on `level`.
    title: ?[]const u8,
) !bool {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const requires_sentinel = comptime isLinuxOrBsd() and options.use_gtk;

    const unwrapped_title = title orelse switch (level) {
        .info => "Info",
        .warn => "Warning",
        .err => "Error",
    };
    const mod_title = if (requires_sentinel)
        try std.fmt.allocPrintSentinel(arena_allocator, "{s}", .{unwrapped_title}, 0)
    else
        unwrapped_title;

    const mod_text = if (requires_sentinel)
        try std.fmt.allocPrintSentinel(arena_allocator, "{s}", .{text}, 0)
    else
        text;

    if (comptime isLinuxOrBsd()) {
        return if (options.use_gtk)
            try gtk.message(level, buttons, mod_text, mod_title)
        else
            try zenity.message(arena_allocator, level, buttons, mod_text, mod_title);
    }

    return switch (builtin.os.tag) {
        .windows => try win.message(arena_allocator, level, buttons, mod_text, mod_title),
        else => @compileError("Unsupported OS"),
    };
}
