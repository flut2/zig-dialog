const std = @import("std");
const builtin = @import("builtin");

const options = @import("options");

const dlg_ns: type = b: {
    if (isLinuxOrBsd())
        break :b if (options.use_gtk)
            @import("dialog/gtk_impl.zig")
        else
            @import("dialog/zenity_impl.zig");
    break :b switch (builtin.os.tag) {
        .windows => @import("dialog/win_impl.zig"),
        else => @compileError("Unsupported OS"),
    };
};

const wind_ns: type = b: {
    if (isLinuxOrBsd())
        break :b if (options.use_wayland)
            @import("window/wl_impl.zig")
        else
            @import("window/x11_impl.zig");
    break :b switch (builtin.os.tag) {
        .windows => @import("window/win_impl.zig"),
        else => @compileError("Unsupported OS"),
    };
};

pub var window_map: std.AutoHashMapUnmanaged(Window.Id, Window) = .empty;
pub var clipboard_window: *Window = undefined;
pub var clipboard_buffer: []u8 = &.{};

var windy_allocator: ?std.mem.Allocator = null;
var vulkan_dyn_lib: if (options.vulkan_support) std.DynLib else void = undefined;

/// Specify `clip_buf` with an appropriately sized buffer if you wish to use
/// `getClipboard()` or `setClipboard()`, as the result/input is copied and stored there
pub fn init(allocator: std.mem.Allocator, clip_buf: []u8) !void {
    windy_allocator = allocator;
    try wind_ns.init();
    const wind = try wind_ns.clipboardWindow();
    try window_map.put(allocator, wind.id, wind);
    clipboard_window = window_map.getPtr(wind.id) orelse unreachable;
    clipboard_buffer = clip_buf;

    if (options.vulkan_support)
        vulkan_dyn_lib = try .open(switch (builtin.os.tag) {
            .windows => "vulkan-1.dll",
            .macos => "libvulkan.1.dylib",
            .openbsd, .netbsd => "libvulkan.so",
            else => "libvulkan.so.1",
        });
}

pub fn deinit() void {
    const allocator = windy_allocator orelse noinit();

    var wind_iter = window_map.valueIterator();
    while (wind_iter.next()) |wind| wind.destroy();
    window_map.deinit(allocator);

    wind_ns.deinit();
    if (options.vulkan_support) vulkan_dyn_lib.close();
}

/// Poll for incoming events, after which the registered (`register[...]Cb()`) events
/// get their callbacks dispatched, if there were any.
pub fn pollEvents() !void {
    try wind_ns.pollEvents();
}

/// Processes a single event, or blocks until it receives one,
/// after which the registered (`register[...]Cb()`) events
/// get their callbacks dispatched, if there were any.
pub fn waitEvent() !void {
    try wind_ns.waitEvent();
}

/// Notes:
/// - This polls events until the clipboard string is dispatched on X11.
/// - This attempts to open the clipboard 5 times on Windows with a 2 ms sleep in between,
/// as the clipboard could be in use by other programs.
///
/// If these are a problem, wrap it in `io.async()` or similar once they're available.
pub fn getClipboard() ![]const u8 {
    return try wind_ns.getClipboard();
}

/// Note: This attempts to open the clipboard 5 times on Windows with a 2 ms sleep in between,
/// as the clipboard could be in use by other programs.
///
/// If this is a problem, wrap it in `io.async()` or similar once they're available.
pub fn setClipboard(new_buf: []const u8) !void {
    try wind_ns.setClipboard(new_buf);
}

pub fn vulkanProcAddr(comptime vk: type, name: [*:0]const u8) vk.PfnVoidFunction {
    if (!options.vulkan_support) @compileError("Please enable Vulkan support with `-Dvulkan_support=true`");
    return vulkan_dyn_lib.lookup(vk.PfnVoidFunction, std.mem.span(name)) orelse null;
}

/// This can be called without `-Dvulkan_support=true` if you wish to do so.
pub fn vulkanExts() []const [*:0]const u8 {
    return wind_ns.vulkanExts();
}

/// Frees the results of `openDialog()` and `saveDialog()`.
pub fn freeResult(result: anytype) void {
    const allocator = windy_allocator orelse noinit();
    switch (@TypeOf(result)) {
        []const u8 => allocator.free(result),
        []const []const u8 => {
            for (result) |val| allocator.free(val);
            allocator.free(result);
        },
        else => |T| @compileError("Invalid type given to `freeResult()`: " ++ @typeName(T)),
    }
}

/// Opens an open dialog of the given type, returns the resulting path(s)
/// once the user is finished interacting with it.
/// Note: Windows assumes input strings to be WTF8 and returns WTF8.
pub fn openDialog(
    comptime multiple_selection: bool,
    dialog_type: DialogType,
    filters: []const Filter,
    /// The title will be set to `Select Folder(s)` or `Select File(s)`
    /// (depending on `dialog_type` and `multiple_selection`) if set to null
    title: ?[]const u8,
    default_path: ?[]const u8,
) !if (multiple_selection) []const []const u8 else []const u8 {
    const allocator = windy_allocator orelse noinit();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const requires_sentinel = comptime isLinuxOrBsd() and options.use_gtk;

    const unwrapped_title = title orelse switch (dialog_type) {
        .directory => "Select Folder" ++ if (multiple_selection) "s" else "",
        .file => "Select File" ++ if (multiple_selection) "s" else "",
    };
    const mod = try modParams(requires_sentinel, arena_allocator, unwrapped_title, default_path, filters);

    return dlg_ns.openDialog(multiple_selection, arena_allocator, allocator, dialog_type, mod.filters, mod.title, mod.default_path);
}

/// Opens a save dialog of the given type, returns the resulting path
/// once the user is finished interacting with it.
/// Note: Windows assumes input strings to be WTF8 and returns WTF8.
pub fn saveDialog(
    filters: []const Filter,
    /// The title will be set to `Save File` if set to null
    title: ?[]const u8,
    default_path: ?[]const u8,
) ![]const u8 {
    const allocator = windy_allocator orelse noinit();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const requires_sentinel = comptime isLinuxOrBsd() and options.use_gtk;

    const unwrapped_title = title orelse "Save File";
    const mod = try modParams(requires_sentinel, arena_allocator, unwrapped_title, default_path, filters);

    return dlg_ns.saveDialog(arena_allocator, allocator, mod.filters, mod.title, mod.default_path);
}

/// Opens a message box of the given level.
/// Returns true if execution was successful and either `Ok` or `Yes` were clicked.
/// Note: Windows assumes input strings to be WTF8.
pub fn message(
    level: MessageLevel,
    buttons: MessageButtons,
    text: []const u8,
    /// The title will be set to `Info`, `Warning` or `Error` if set to null,
    /// depending on `level`.
    title: ?[]const u8,
) !bool {
    const allocator = windy_allocator orelse noinit();

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

    return dlg_ns.message(arena_allocator, level, buttons, mod_text, mod_title);
}

/// Opens a color chooser dialog, setting the initial value to `color`.
/// Returns the selected color in RGBA, or `error.Canceled` if the dialog is canceled.
/// Note: Windows assumes input strings to be WTF8 and ignores `use_alpha` and `title`, as they're unsupported.
pub fn colorChooser(
    color: Rgba,
    use_alpha: bool,
    /// The title will be set to `Choose a Color` if set to null.
    title: ?[]const u8,
) !Rgba {
    const allocator = windy_allocator orelse noinit();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const requires_sentinel = comptime isLinuxOrBsd() and options.use_gtk;

    const unwrapped_title = title orelse "Choose a Color";
    const mod_title = if (requires_sentinel)
        try std.fmt.allocPrintSentinel(arena_allocator, "{s}", .{unwrapped_title}, 0)
    else
        unwrapped_title;

    return dlg_ns.colorChooser(arena_allocator, color, use_alpha, mod_title);
}

/// Do not modify fields from user code, will cause issues
pub const Window = struct {
    pub const Id = u64;
    pub const Options = struct {
        back_pixel: BackPixel = .white,
        title: ?[:0]const u8 = null,
        start_pos: ?Position = null,
    };

    pub const invalid: Window = .{ .id = std.math.maxInt(Id) };

    fn PlatformWindowInfo() type {
        if (isLinuxOrBsd()) {
            return if (options.use_wayland)
                struct {}
            else
                struct {
                    event_mask_list: i32 = 0,
                    size_hints: wind_ns.SizeHints = .{},
                };
        }

        return switch (builtin.os.tag) {
            .windows => struct {
                const win32 = @import("win32").ui.windows_and_messaging;

                style: win32.WINDOW_STYLE = .{},
                ex_style: win32.WINDOW_EX_STYLE = .{},
                surrogate: u16 = 0,
                cursor: ?Cursor = null,
                mods: Mods = .{},
                min_size: Size = .invalid,
                max_size: Size = .invalid,
                resize_incr: Size = .invalid,
                aspect_numerator: u16 = std.math.maxInt(u16),
                aspect_denominator: u16 = std.math.maxInt(u16),
            },
            else => @compileError("Unsupported OS"),
        };
    }

    id: Id,
    should_close: bool = false,
    size: Size = .invalid,
    pos: Position = .invalid,
    callbacks: Callbacks = .{},
    platform: PlatformWindowInfo() = .{},

    pub fn create(w: u16, h: u16, opts: Options) !*Window {
        const allocator = windy_allocator orelse noinit();
        const window = try wind_ns.createWindow(allocator, w, h, opts);
        try window_map.put(allocator, window.id, window);
        return window_map.getPtr(window.id) orelse unreachable;
    }

    pub fn destroy(self: Window) void {
        if (windy_allocator == null) noinit();
        wind_ns.destroyWindow(self);
        if (!window_map.remove(self.id))
            std.log.err("Removing window from the internal map failed", .{})
        else {
            // Window destruction should be sporadic, while map access is
            // usually constant (events), so rehash each destroy
            const dummy_ctx: std.hash_map.AutoContext(Window.Id) = undefined;
            window_map.rehash(&dummy_ctx);
        }
    }

    /// This can be called without `-Dvulkan_support=true` if you wish to do so.
    pub fn createSurface(self: Window, comptime vk: type, inst: vk.InstanceProxy) !vk.SurfaceKHR {
        return try wind_ns.createSurface(vk, self, inst);
    }

    pub fn setTitle(self: Window, title: [:0]const u8) !void {
        const allocator = windy_allocator orelse noinit();
        try wind_ns.setTitle(allocator, self.id, title);
    }

    pub fn setCursor(self: *Window, cursor: Cursor) !void {
        if (windy_allocator == null) noinit();
        try wind_ns.setCursor(self, cursor);
    }

    pub fn setMinSize(self: *Window, min_size: Size) !void {
        if (windy_allocator == null) noinit();
        try wind_ns.setMinWindowSize(self, min_size);
    }

    pub fn setMaxSize(self: *Window, max_size: Size) !void {
        if (windy_allocator == null) noinit();
        try wind_ns.setMaxWindowSize(self, max_size);
    }

    pub fn setResizeIncr(self: *Window, incr_size: Size) !void {
        if (windy_allocator == null) noinit();
        try wind_ns.setWindowResizeIncr(self, incr_size);
    }

    pub fn setAspect(self: *Window, numerator: u16, denominator: u16) !void {
        if (windy_allocator == null) noinit();
        try wind_ns.setWindowAspect(self, numerator, denominator);
    }

    pub fn resize(self: Window, size: Size) !void {
        if (windy_allocator == null) noinit();
        try wind_ns.resizeWindow(self, size);
    }

    pub fn move(self: Window, pos: Position) !void {
        if (windy_allocator == null) noinit();
        try wind_ns.moveWindow(self, pos);
    }

    pub fn registerRefreshCb(self: *Window, cb: ?refreshCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.refresh = cb;
        // Registrations are only required with XCB for now
        if (std.meta.hasFn(wind_ns, "registerRefreshCb"))
            try wind_ns.registerRefreshCb(self, cb != null);
    }

    pub fn registerResizeCb(self: *Window, cb: ?resizeCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.resize = cb;
        if (std.meta.hasFn(wind_ns, "registerConfigure"))
            try wind_ns.registerConfigure(self, cb != null);
    }

    pub fn registerMoveCb(self: *Window, cb: ?moveCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.move = cb;
        if (std.meta.hasFn(wind_ns, "registerConfigure"))
            try wind_ns.registerConfigure(self, cb != null);
    }

    pub fn registerKeyCb(self: *Window, cb: ?keyCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.key = cb;
        if (std.meta.hasFn(wind_ns, "registerKeyCb"))
            try wind_ns.registerKeyCb(self, cb != null);
    }

    pub fn registerCharCb(self: *Window, cb: ?charCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.char = cb;
        if (std.meta.hasFn(wind_ns, "registerKeyCb"))
            // This uses key events, the only difference is the way the callbacks return data
            try wind_ns.registerKeyCb(self, cb != null);
    }

    pub fn registerMouseCb(self: *Window, cb: ?mouseCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.mouse = cb;
        if (std.meta.hasFn(wind_ns, "registerMouseCb"))
            try wind_ns.registerMouseCb(self, cb != null);
    }

    pub fn registerMouseMoveCb(self: *Window, cb: ?mouseMoveCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.mouseMove = cb;
        if (std.meta.hasFn(wind_ns, "registerMouseMoveCb"))
            try wind_ns.registerMouseMoveCb(self, cb != null);
    }

    pub fn registerScrollCb(self: *Window, cb: ?scrollCallback) !void {
        if (windy_allocator == null) noinit();
        self.callbacks.scroll = cb;
        if (std.meta.hasFn(wind_ns, "registerScrollCb"))
            try wind_ns.registerScrollCb(self, cb != null);
    }
};

/// Do not modify fields from user code, will cause issues
pub const Cursor = struct {
    pub const Id = u64;

    pub const invalid: Cursor = .{ .id = std.math.maxInt(Id) };

    id: Id,

    /// The supplied image must be 32-bit ARGB.
    pub fn create(argb_raw_img: []const u8, w: u16, h: u16, x_hot: u16, y_hot: u16) !Cursor {
        if (windy_allocator == null) noinit();
        return try wind_ns.createCursor(argb_raw_img, w, h, x_hot, y_hot);
    }

    pub fn destroy(self: Cursor) void {
        if (windy_allocator == null) noinit();
        wind_ns.destroyCursor(self);
    }
};

pub const PressState = enum { press, release };
pub const BackPixel = enum { white, black };
pub const Position = struct {
    x: i16,
    y: i16,

    pub const invalid: Position = .{
        .x = std.math.minInt(i16),
        .y = std.math.minInt(i16),
    };

    pub fn eql(self: Position, other: Position) bool {
        return self.x == other.x and self.y == other.y;
    }
};
pub const Size = struct {
    w: u16,
    h: u16,

    pub const invalid: Size = .{
        .w = std.math.maxInt(u16),
        .h = std.math.maxInt(u16),
    };

    pub fn eql(self: Size, other: Size) bool {
        return self.w == other.w and self.h == other.h;
    }
};

pub const refreshCallback = *const fn (wind: *Window) void;
pub const resizeCallback = *const fn (wind: *Window, w: u16, h: u16) void;
pub const moveCallback = *const fn (wind: *Window, x: i16, y: i16) void;
pub const keyCallback = *const fn (wind: *Window, state: PressState, key: Key, mods: Mods) void;
pub const charCallback = *const fn (wind: *Window, char: u21, mods: Mods) void;
pub const mouseCallback = *const fn (wind: *Window, state: PressState, mouse: MouseButton, x: i16, y: i16, mods: Mods) void;
pub const mouseMoveCallback = *const fn (wind: *Window, x: i16, y: i16, mods: Mods) void;
pub const scrollCallback = *const fn (wind: *Window, x: f32, y: f32, mods: Mods) void;

pub const Callbacks = struct {
    refresh: ?refreshCallback = null,
    resize: ?resizeCallback = null,
    move: ?moveCallback = null,
    key: ?keyCallback = null,
    char: ?charCallback = null,
    mouse: ?mouseCallback = null,
    mouseMove: ?mouseMoveCallback = null,
    scroll: ?scrollCallback = null,
};

pub const Mods = packed struct {
    shift: bool = false,
    caps_lock: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    num_lock: bool = false,
    super: bool = false,
};

pub const Key = enum {
    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_decimal,
    kp_equal,
    kp_enter,
    left_shift,
    right_shift,
    left_control,
    right_control,
    left_alt,
    right_alt,
    left_super,
    right_super,
    left_bracket,
    right_bracket,
    less_than,
    greater_than,
    num_lock,
    caps_lock,
    scroll_lock,
    page_up,
    page_down,
    left,
    right,
    up,
    down,
    minus,
    equal,
    enter,
    escape,
    tab,
    backspace,
    space,
    semicolon,
    apostrophe,
    comma,
    period,
    grave_accent,
    backslash,
    slash,
    pause,
    delete,
    home,
    end,
    insert,
    menu,
    print,

    invalid,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    m4,
    m5,
    m6,
    m7,
    m8,
    m9,
    m10,
    m11,
    m12,
    m13,
    m14,
    m15,
    m16,
    m17,
    m18,
    m19,
    m20,
    m21,
    m22,
    m23,
    m24,
    m25,
    m26,
    m27,
    m28,
    m29,
    m30,
    m31,
    m32,

    invalid,
};

pub const MessageLevel = enum { info, warn, err };
pub const MessageButtons = enum { yes_no, ok_cancel, ok };
pub const DialogType = enum { file, directory };
pub const Rgba = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn fromColor(rgb: u32, alpha: f32) Rgba {
        return .{
            .r = @intCast((rgb >> 16) & 255),
            .g = @intCast((rgb >> 8) & 255),
            .b = @intCast(rgb & 255),
            .a = @intFromFloat(255.0 * alpha),
        };
    }

    pub fn toColor(self: Rgba) u32 {
        return @as(u32, @intCast(self.r)) << 16 |
            @as(u32, @intCast(self.g)) << 8 |
            @as(u32, @intCast(self.b));
    }
};

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

fn noinit() noreturn {
    @panic("Windy: Attempted to use the library without initializing it");
}

fn isLinuxOrBsd() bool {
    return builtin.os.tag == .linux or builtin.os.tag.isBSD();
}
