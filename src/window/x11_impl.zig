const std = @import("std");

const windy = @import("../windy.zig");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xkb.h");
    @cInclude("xcb/render.h");
    @cInclude("xcb/xcb_renderutil.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

const SizeAspect = extern struct {
    numerator: i32 = 0,
    denominator: i32 = 0,
};
pub const SizeHints = extern struct {
    flags: packed struct(i32) {
        user_pos: bool = false,
        user_size: bool = false,
        prog_pos: bool = false,
        prog_size: bool = false,
        prog_min_size: bool = false,
        prog_max_size: bool = false,
        prog_resize_inc: bool = false,
        prog_aspect: bool = false,
        prog_base_size: bool = false,
        prog_gravity: bool = false,
        pad: u22 = 0,
    } = .{},
    /// Formerly `x`, now unused
    pad1: i32 = 0,
    /// Formerly `y`, now unused
    pad2: i32 = 0,
    /// Formerly `width`, now unused
    pad3: i32 = 0,
    /// Formerly `height`, now unused
    pad4: i32 = 0,
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,
    width_inc: i32 = 0,
    height_inc: i32 = 0,
    min_aspect: SizeAspect = .{},
    max_aspect: SizeAspect = .{},
    base_w: i32 = 0,
    base_h: i32 = 0,
    gravity: i32 = 0,
};

var xcb: struct {
    conn: *c.xcb_connection_t = undefined,
    screen: *c.xcb_screen_t = undefined,

    wm_prot_atom: c.xcb_atom_t = c.XCB_ATOM_NONE,
    wind_del_atom: c.xcb_atom_t = c.XCB_ATOM_NONE,
    clipboard_atom: c.xcb_atom_t = c.XCB_ATOM_NONE,
    utf8_atom: c.xcb_atom_t = c.XCB_ATOM_NONE,
    xsel_atom: c.xcb_atom_t = c.XCB_ATOM_NONE,
    targets_atom: c.xcb_atom_t = c.XCB_ATOM_NONE,
    timestamp_atom: c.xcb_atom_t = c.XCB_ATOM_NONE,
} = .{};

var xkb: struct {
    ctx: *c.xkb_context = undefined,
    keymap: *c.xkb_keymap = undefined,
    state: *c.xkb_state = undefined,
    core_dvid: i32 = std.math.minInt(i32),
    base_evt: u8 = std.math.maxInt(u8),
} = .{};

var owned_selection: []u8 = &.{};

pub fn init() !void {
    var screen_num: i32 = 0;
    xcb.conn = c.xcb_connect(null, &screen_num).?;
    errdefer c.xcb_disconnect(xcb.conn);
    try processConnErr(c.xcb_connection_has_error(xcb.conn));

    xcb.wm_prot_atom = try atom("WM_PROTOCOLS");
    xcb.wind_del_atom = try atom("WM_DELETE_WINDOW");
    xcb.clipboard_atom = try atom("CLIPBOARD");
    xcb.utf8_atom = try atom("UTF8_STRING");
    xcb.xsel_atom = try atom("XSEL_DATA");
    xcb.targets_atom = try atom("TARGETS");
    xcb.timestamp_atom = try atom("TIMESTAMP");

    var iter = c.xcb_setup_roots_iterator(c.xcb_get_setup(xcb.conn));
    if (iter.rem < screen_num) return error.InvalidScreen;
    for (0..@as(usize, @intCast(screen_num))) |_|
        c.xcb_screen_next(&iter);
    xcb.screen = iter.data;

    if (c.xkb_x11_setup_xkb_extension(
        xcb.conn,
        c.XKB_X11_MIN_MAJOR_XKB_VERSION,
        c.XKB_X11_MIN_MINOR_XKB_VERSION,
        c.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
        null,
        null,
        &xkb.base_evt,
        null,
    ) == 0)
        return error.XkbSetupFailed;

    xkb.ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
        return error.ContextInitFailed;
    errdefer c.xkb_context_unref(xkb.ctx);

    xkb.core_dvid = c.xkb_x11_get_core_keyboard_device_id(xcb.conn);
    if (xkb.core_dvid == -1)
        return error.KeyboardMissing;

    const required_map_parts = c.XCB_XKB_MAP_PART_KEY_TYPES |
        c.XCB_XKB_MAP_PART_KEY_SYMS |
        c.XCB_XKB_MAP_PART_MODIFIER_MAP |
        c.XCB_XKB_MAP_PART_EXPLICIT_COMPONENTS |
        c.XCB_XKB_MAP_PART_KEY_ACTIONS |
        c.XCB_XKB_MAP_PART_VIRTUAL_MODS |
        c.XCB_XKB_MAP_PART_VIRTUAL_MOD_MAP;

    const required_state_details = c.XCB_XKB_STATE_PART_MODIFIER_BASE |
        c.XCB_XKB_STATE_PART_MODIFIER_LATCH |
        c.XCB_XKB_STATE_PART_MODIFIER_LOCK |
        c.XCB_XKB_STATE_PART_GROUP_BASE |
        c.XCB_XKB_STATE_PART_GROUP_LATCH |
        c.XCB_XKB_STATE_PART_GROUP_LOCK;

    const values: c.xcb_xkb_select_events_details_t = .{
        .affectNewKeyboard = c.XCB_XKB_NKN_DETAIL_KEYCODES,
        .newKeyboardDetails = c.XCB_XKB_NKN_DETAIL_KEYCODES,
        .affectState = required_state_details,
        .stateDetails = required_state_details,
    };
    try check(c.xcb_xkb_select_events_aux_checked(
        xcb.conn,
        @as(u16, @intCast(xkb.core_dvid)),
        c.XCB_XKB_EVENT_TYPE_NEW_KEYBOARD_NOTIFY |
            c.XCB_XKB_EVENT_TYPE_MAP_NOTIFY |
            c.XCB_XKB_EVENT_TYPE_STATE_NOTIFY,
        0,
        0,
        required_map_parts,
        required_map_parts,
        &values,
    ));

    const flag_cookie = c.xcb_xkb_per_client_flags(xcb.conn, @intCast(xkb.core_dvid), c.XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT, 1, 0, 0, 0);
    var flag_err: [*c]c.xcb_generic_error_t = null;
    _ = c.xcb_xkb_per_client_flags_reply(xcb.conn, flag_cookie, &flag_err);
    if (flag_err) |err| try processErr(err);

    xkb.keymap = c.xkb_x11_keymap_new_from_device(
        xkb.ctx,
        xcb.conn,
        xkb.core_dvid,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.InvalidKeymap;
    errdefer c.xkb_keymap_unref(xkb.keymap);
    xkb.state = c.xkb_x11_state_new_from_device(
        xkb.keymap,
        xcb.conn,
        xkb.core_dvid,
    ) orelse return error.InvalidKeyState;
    errdefer c.xkb_keymap_unref(xkb.state);
}

pub fn deinit() void {
    c.xkb_keymap_unref(xkb.keymap);
    c.xkb_state_unref(xkb.state);
    c.xkb_context_unref(xkb.ctx);
    c.xcb_disconnect(xcb.conn);
}

pub fn createWindow(allocator: std.mem.Allocator, w: u16, h: u16, opts: windy.Window.Options) !windy.Window {
    const wid = c.xcb_generate_id(xcb.conn);

    const start_pos: windy.Position = opts.start_pos orelse .{
        .x = @intCast((xcb.screen.width_in_pixels - w) / 2),
        .y = @intCast((xcb.screen.height_in_pixels - h) / 2),
    };

    if (start_pos.x >= xcb.screen.width_in_pixels or start_pos.y >= xcb.screen.height_in_pixels)
        return error.StartPosOutOfBounds;

    const values = [_]u32{switch (opts.back_pixel) {
        .white => xcb.screen.white_pixel,
        .black => xcb.screen.black_pixel,
    }};
    try check(c.xcb_create_window_checked(
        xcb.conn,
        xcb.screen.root_depth,
        wid,
        xcb.screen.root,
        start_pos.x,
        start_pos.y,
        w,
        h,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        xcb.screen.root_visual,
        c.XCB_CW_BACK_PIXEL,
        &values,
    ));

    try check(c.xcb_change_property_checked(
        xcb.conn,
        c.XCB_PROP_MODE_REPLACE,
        wid,
        xcb.wm_prot_atom,
        c.XCB_ATOM_ATOM,
        32,
        1,
        &xcb.wind_del_atom,
    ));

    if (opts.title) |title| try setTitle(allocator, wid, title);

    try check(c.xcb_map_window_checked(xcb.conn, wid));
    try tryFlush();

    return .{
        .id = wid,
        .size = .{ .w = w, .h = h },
        .pos = start_pos,
    };
}

pub fn clipboardWindow() !windy.Window {
    const wid = c.xcb_generate_id(xcb.conn);

    const values = [_]u32{c.XCB_EVENT_MASK_PROPERTY_CHANGE};
    try check(c.xcb_create_window_checked(
        xcb.conn,
        c.XCB_COPY_FROM_PARENT,
        wid,
        xcb.screen.root,
        0,
        0,
        1,
        1,
        0,
        c.XCB_WINDOW_CLASS_COPY_FROM_PARENT,
        xcb.screen.root_visual,
        c.XCB_CW_EVENT_MASK,
        &values,
    ));
    try check(c.xcb_convert_selection_checked(
        xcb.conn,
        wid,
        xcb.clipboard_atom,
        xcb.utf8_atom,
        xcb.xsel_atom,
        c.XCB_CURRENT_TIME,
    ));

    try tryFlush();

    return .{
        .id = wid,
        .size = .{ .w = 1, .h = 1 },
        .pos = .{ .x = 0, .y = 0 },
    };
}

pub fn destroyWindow(wind: windy.Window) void {
    // swallow error to make defer easier
    check(c.xcb_destroy_window_checked(xcb.conn, @as(u32, @intCast(wind.id)))) catch |e|
        std.log.err("Received error `{}` during window destroy", .{e});
}

pub fn createSurface(comptime vk: type, wind: windy.Window, inst: vk.InstanceProxy) !vk.SurfaceKHR {
    const sci: vk.XcbSurfaceCreateInfoKHR = .{
        .connection = @ptrCast(xcb.conn),
        .window = @intCast(wind.id),
    };
    return try inst.createXcbSurfaceKHR(&sci, null);
}

pub fn vulkanExts() []const [*:0]const u8 {
    return &.{ "VK_KHR_surface", "VK_KHR_xcb_surface" };
}

pub fn createCursor(
    argb_raw_img: []const u8,
    w: u16,
    h: u16,
    x_hot: u16,
    y_hot: u16,
) !windy.Cursor {
    const pid = c.xcb_generate_id(xcb.conn);
    try check(c.xcb_create_pixmap_checked(xcb.conn, @bitSizeOf(i32), pid, xcb.screen.root, w, h));

    const gcid = c.xcb_generate_id(xcb.conn);
    try check(c.xcb_create_gc_checked(xcb.conn, gcid, pid, 0, null));

    try check(c.xcb_put_image_checked(
        xcb.conn,
        c.XCB_IMAGE_FORMAT_Z_PIXMAP,
        pid,
        gcid,
        w,
        h,
        0,
        0,
        0,
        @bitSizeOf(i32),
        @as(u32, @intCast(argb_raw_img.len)),
        argb_raw_img.ptr,
    ));

    const cookie = c.xcb_render_query_pict_formats(xcb.conn);
    const formats = c.xcb_render_query_pict_formats_reply(xcb.conn, cookie, null);
    defer std.c.free(formats);
    const format = c.xcb_render_util_find_standard_format(formats, c.XCB_PICT_STANDARD_ARGB_32).*.id;

    const pcid = c.xcb_generate_id(xcb.conn);
    try check(c.xcb_render_create_picture_checked(xcb.conn, pcid, pid, format, 0, null));

    const cid = c.xcb_generate_id(xcb.conn);
    try check(c.xcb_render_create_cursor_checked(xcb.conn, cid, pcid, x_hot, y_hot));

    try check(c.xcb_render_free_picture_checked(xcb.conn, pcid));
    try check(c.xcb_free_gc_checked(xcb.conn, gcid));
    try check(c.xcb_free_pixmap_checked(xcb.conn, pid));

    return .{ .id = cid };
}

pub fn destroyCursor(cursor: windy.Cursor) void {
    // swallow error to make defer easier
    check(c.xcb_free_cursor_checked(xcb.conn, @as(u32, @intCast(cursor.id)))) catch |e|
        std.log.err("Received error `{}` during cursor destroy", .{e});
}

pub fn pollEvents() !void {
    try internalPoll(false);
}

pub fn waitEvent() !void {
    try handleEvent(c.xcb_wait_for_event(xcb.conn));
}

/// Returns when we run out of events, or we receive a selection notify event,
/// if requested through `early_ret`.
fn internalPoll(early_ret: bool) !void {
    var evt = c.xcb_poll_for_event(xcb.conn);
    while (evt) |e| : (evt = c.xcb_poll_for_event(xcb.conn)) {
        try handleEvent(e);
        if (early_ret and e.*.response_type & ~@as(u8, 0x80) == c.XCB_SELECTION_NOTIFY) return;
    }
}

fn handleEvent(e: [*c]c.xcb_generic_event_t) !void {
    defer std.c.free(e);

    const resp = e.*.response_type;
    switch (resp & ~@as(u8, 0x80)) {
        // TODO: handle these properly
        c.XCB_REPARENT_NOTIFY, c.XCB_MAP_NOTIFY, c.XCB_PROPERTY_NOTIFY => {},
        c.XCB_SELECTION_CLEAR => {
            if (windy.clipboard_buffer.len >= owned_selection.len)
                @memset(windy.clipboard_buffer[0..owned_selection.len], 0);
            owned_selection = &.{};
        },
        c.XCB_SELECTION_NOTIFY => {
            const notify: *c.xcb_selection_notify_event_t = @ptrCast(e);
            if (notify.property != xcb.clipboard_atom) return;

            var format: u8 = @sizeOf(i32);
            var bytes: u32 = 1;
            var offset: u32 = 0;
            while (bytes > 0) {
                var prop_err: [*c]c.xcb_generic_error_t = null;
                const reply = c.xcb_get_property_reply(
                    xcb.conn,
                    c.xcb_get_property(
                        xcb.conn,
                        1,
                        @intCast(windy.clipboard_window.id),
                        notify.property,
                        c.XCB_ATOM_ANY,
                        offset / format,
                        std.math.maxInt(u16),
                    ),
                    &prop_err,
                );
                defer std.c.free(reply);
                if (prop_err) |err| try processErr(err);

                if (offset == 0) format = reply.*.format / 8;

                const len: u32 = @intCast(c.xcb_get_property_value_length(reply) * format);
                if (len <= 0) {
                    bytes = reply.*.bytes_after;
                    continue;
                }

                if (offset + len > windy.clipboard_buffer.len) return error.OutOfMemory;

                const data: [*]u8 = @ptrCast(c.xcb_get_property_value(reply) orelse return error.InvalidSelection);
                @memcpy(windy.clipboard_buffer[offset..][0..len], data[0..len]);
                offset += len;
                bytes = reply.*.bytes_after;
            }

            if (offset > windy.clipboard_buffer.len) return error.OutOfMemory;
            owned_selection = windy.clipboard_buffer[0..offset];
        },
        c.XCB_SELECTION_REQUEST => {
            const req: *c.xcb_selection_request_event_t = @ptrCast(e);

            var prop: c.xcb_atom_t = req.property;
            if (req.target == xcb.targets_atom) {
                const targets = [_]c.xcb_atom_t{ xcb.timestamp_atom, xcb.targets_atom, xcb.utf8_atom };
                try check(c.xcb_change_property_checked(
                    xcb.conn,
                    c.XCB_PROP_MODE_REPLACE,
                    req.requestor,
                    req.property,
                    c.XCB_ATOM_ATOM,
                    @bitSizeOf(c.xcb_atom_t),
                    targets.len,
                    &targets,
                ));
            } else if (req.target == xcb.timestamp_atom) {
                const cur = std.time.timestamp();
                try check(c.xcb_change_property_checked(
                    xcb.conn,
                    c.XCB_PROP_MODE_REPLACE,
                    req.requestor,
                    req.property,
                    c.XCB_ATOM_INTEGER,
                    @bitSizeOf(@TypeOf(cur)),
                    1,
                    &cur,
                ));
            } else if (req.target == xcb.utf8_atom) try check(c.xcb_change_property_checked(
                xcb.conn,
                c.XCB_PROP_MODE_REPLACE,
                req.requestor,
                req.property,
                req.target,
                @bitSizeOf(u8),
                @intCast(owned_selection.len),
                owned_selection.ptr,
            )) else prop = c.XCB_ATOM_NONE;

            const notify: c.xcb_selection_notify_event_t = .{
                .response_type = c.XCB_SELECTION_NOTIFY,
                .time = c.XCB_CURRENT_TIME,
                .requestor = req.requestor,
                .selection = req.selection,
                .target = req.target,
                .property = prop,
            };
            try check(c.xcb_send_event_checked(xcb.conn, 0, req.requestor, c.XCB_EVENT_MASK_PROPERTY_CHANGE, @ptrCast(&notify)));
            try tryFlush();
        },
        c.XCB_CLIENT_MESSAGE => {
            const msg: *c.xcb_client_message_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(msg.window) orelse return error.WindowMissing;
            if (msg.type == xcb.wm_prot_atom and msg.data.data32[0] == xcb.wind_del_atom)
                wind.should_close = true;
        },
        c.XCB_CONFIGURE_NOTIFY => {
            const cfg: *c.xcb_configure_notify_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(cfg.window) orelse return error.WindowMissing;

            if (wind.size.w != cfg.width or wind.size.h != cfg.height) {
                wind.size = .{ .w = cfg.width, .h = cfg.height };
                if (wind.callbacks.resize) |cb| cb(wind, cfg.width, cfg.height);
            }

            // TODO: these could be relative positions
            if (wind.pos.x != cfg.x or wind.pos.y != cfg.y) {
                wind.pos = .{ .x = cfg.x, .y = cfg.y };
                if (wind.callbacks.move) |cb| cb(wind, cfg.x, cfg.y);
            }
        },
        c.XCB_EXPOSE => {
            const exp: *c.xcb_expose_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(exp.window) orelse return error.WindowMissing;
            if (wind.callbacks.refresh) |cb| cb(wind);
        },
        c.XCB_KEY_PRESS => {
            const press: *c.xcb_key_press_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(press.event) orelse return error.WindowMissing;
            const sym = c.xkb_state_key_get_one_sym(xkb.state, press.detail);
            const mods = toMods(press.state);
            if (wind.callbacks.key) |cb| cb(wind, .press, symToKey(sym), mods);
            if (wind.callbacks.char) |cb| cb(wind, @intCast(c.xkb_keysym_to_utf32(sym)), mods);
        },
        c.XCB_KEY_RELEASE => {
            const release: *c.xcb_key_release_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(release.event) orelse return error.WindowMissing;
            const sym = c.xkb_state_key_get_one_sym(xkb.state, release.detail);
            const mods = toMods(release.state);
            if (wind.callbacks.key) |cb| cb(wind, .release, symToKey(sym), mods);
        },
        c.XCB_BUTTON_PRESS => {
            const press: *c.xcb_button_press_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(press.event) orelse return error.WindowMissing;
            const mods = toMods(press.state);
            const scrollCb = wind.callbacks.scroll;
            switch (press.detail) {
                4 => (scrollCb orelse return)(wind, 0.0, 1.0, mods),
                5 => (scrollCb orelse return)(wind, 0.0, -1.0, mods),
                6 => (scrollCb orelse return)(wind, 1.0, 0.0, mods),
                7 => (scrollCb orelse return)(wind, -1.0, 0.0, mods),
                else => if (wind.callbacks.mouse) |cb| cb(
                    wind,
                    .press,
                    buttonToMouse(press.detail),
                    press.event_x,
                    press.event_y,
                    mods,
                ),
            }
        },
        c.XCB_BUTTON_RELEASE => {
            const release: *c.xcb_button_release_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(release.event) orelse return error.WindowMissing;
            const mods = toMods(release.state);
            const scrollCb = wind.callbacks.scroll;
            switch (release.detail) {
                4 => (scrollCb orelse return)(wind, 0.0, 1.0, mods),
                5 => (scrollCb orelse return)(wind, 0.0, -1.0, mods),
                6 => (scrollCb orelse return)(wind, 1.0, 0.0, mods),
                7 => (scrollCb orelse return)(wind, -1.0, 0.0, mods),
                else => if (wind.callbacks.mouse) |cb| cb(
                    wind,
                    .release,
                    buttonToMouse(release.detail),
                    release.event_x,
                    release.event_y,
                    mods,
                ),
            }
        },
        c.XCB_MOTION_NOTIFY => {
            const move: *c.xcb_motion_notify_event_t = @ptrCast(e);
            const wind = windy.window_map.getPtr(move.event) orelse return error.WindowMissing;
            if (wind.callbacks.mouseMove) |cb| cb(wind, move.event_x, move.event_y, toMods(move.state));
        },
        else => |ty| if (resp == xkb.base_evt) {
            const xkb_any_event: *extern struct {
                response_type: u8,
                xkb_type: u8,
                sequence: u16,
                time: c.xcb_timestamp_t,
                device_id: u8,
            } = @ptrCast(e);

            if (xkb_any_event.device_id == xkb.core_dvid) switch (xkb_any_event.xkb_type) {
                c.XCB_XKB_NEW_KEYBOARD_NOTIFY => {
                    const new_kb: *c.xcb_xkb_new_keyboard_notify_event_t = @ptrCast(e);
                    if (new_kb.changed & c.XCB_XKB_NKN_DETAIL_KEYCODES != 0)
                        try updateKeymaps();
                },
                c.XCB_XKB_MAP_NOTIFY => try updateKeymaps(),
                c.XCB_XKB_STATE_NOTIFY => {
                    const state: *c.xcb_xkb_state_notify_event_t = @ptrCast(e);
                    _ = c.xkb_state_update_mask(
                        xkb.state,
                        state.baseMods,
                        state.latchedMods,
                        state.lockedMods,
                        @intCast(state.baseGroup),
                        @intCast(state.latchedGroup),
                        @intCast(state.lockedGroup),
                    );
                },
                else => |xkb_ty| std.log.debug("Unhandled XKB event type: {}", .{xkb_ty}),
            };
        } else std.log.debug("Unhandled XCB event type: {}", .{ty}),
    }
}

pub fn getClipboard() ![]const u8 {
    var err: [*c]c.xcb_generic_error_t = null;
    const reply = c.xcb_get_selection_owner_reply(
        xcb.conn,
        c.xcb_get_selection_owner(xcb.conn, xcb.clipboard_atom),
        &err,
    ) orelse return &.{};
    defer std.c.free(reply);
    if (err) |e| try processErr(e);

    const owner_wid = reply.*.owner;
    if (owner_wid == 0) return &.{};

    if (owner_wid == @as(u32, @intCast(windy.clipboard_window.id)))
        return owned_selection;

    try check(c.xcb_convert_selection_checked(
        xcb.conn,
        @intCast(windy.clipboard_window.id),
        xcb.clipboard_atom,
        xcb.utf8_atom,
        xcb.xsel_atom,
        c.XCB_CURRENT_TIME,
    ));
    try tryFlush();

    try internalPoll(true);
    return owned_selection;
}

pub fn setClipboard(new_buf: []const u8) !void {
    if (new_buf.len > windy.clipboard_buffer.len) return error.OutOfMemory;
    const buf = windy.clipboard_buffer[0..new_buf.len];
    @memcpy(buf, new_buf);
    owned_selection = buf;
    try check(c.xcb_set_selection_owner_checked(
        xcb.conn,
        @intCast(windy.clipboard_window.id),
        xcb.clipboard_atom,
        c.XCB_CURRENT_TIME,
    ));
    try tryFlush();
}

pub fn setTitle(allocator: std.mem.Allocator, wid: windy.Window.Id, title: [:0]const u8) !void {
    inline for (.{ c.XCB_ATOM_WM_NAME, c.XCB_ATOM_WM_ICON_NAME }) |prop|
        try check(c.xcb_change_property_checked(
            xcb.conn,
            c.XCB_PROP_MODE_REPLACE,
            @as(u32, @intCast(wid)),
            prop,
            c.XCB_ATOM_STRING,
            @bitSizeOf(u8),
            @as(u32, @intCast(title.len)),
            title.ptr,
        ));

    const class_str = try std.fmt.allocPrint(allocator, "windowName\x00{s}\x00", .{title});
    defer allocator.free(class_str);
    try check(c.xcb_change_property_checked(
        xcb.conn,
        c.XCB_PROP_MODE_REPLACE,
        @as(u32, @intCast(wid)),
        c.XCB_ATOM_WM_CLASS,
        c.XCB_ATOM_STRING,
        @bitSizeOf(u8),
        @as(u32, @intCast(class_str.len)),
        class_str.ptr,
    ));
}

pub fn setCursor(wind: *windy.Window, cursor: windy.Cursor) !void {
    const vals = [_]u32{@intCast(cursor.id)};
    try check(c.xcb_change_window_attributes_checked(
        xcb.conn,
        @as(u32, @intCast(wind.id)),
        c.XCB_CW_CURSOR,
        &vals,
    ));

    try tryFlush();
}

pub fn setMinWindowSize(wind: *windy.Window, min_size: windy.Size) !void {
    var size_hints = &wind.platform.size_hints;
    if (size_hints.flags.prog_min_size and
        size_hints.min_width == min_size.w and
        size_hints.min_height == min_size.h)
        return;

    size_hints.flags.prog_min_size = true;
    size_hints.min_width = min_size.w;
    size_hints.min_height = min_size.h;

    try check(c.xcb_change_property_checked(
        xcb.conn,
        c.XCB_PROP_MODE_REPLACE,
        @intCast(wind.id),
        c.XCB_ATOM_WM_NORMAL_HINTS,
        c.XCB_ATOM_WM_SIZE_HINTS,
        @bitSizeOf(i32),
        @sizeOf(SizeHints) / @sizeOf(i32),
        size_hints,
    ));
    try tryFlush();
}

pub fn setMaxWindowSize(wind: *windy.Window, max_size: windy.Size) !void {
    var size_hints = &wind.platform.size_hints;
    if (size_hints.flags.prog_max_size and
        size_hints.max_width == max_size.w and
        size_hints.max_height == max_size.h)
        return;

    size_hints.flags.prog_max_size = true;
    size_hints.max_width = max_size.w;
    size_hints.max_height = max_size.h;

    try check(c.xcb_change_property_checked(
        xcb.conn,
        c.XCB_PROP_MODE_REPLACE,
        @intCast(wind.id),
        c.XCB_ATOM_WM_NORMAL_HINTS,
        c.XCB_ATOM_WM_SIZE_HINTS,
        @bitSizeOf(i32),
        @sizeOf(SizeHints) / @sizeOf(i32),
        size_hints,
    ));
    try tryFlush();
}

pub fn setWindowResizeIncr(wind: *windy.Window, incr_size: windy.Size) !void {
    var size_hints = &wind.platform.size_hints;
    if (size_hints.flags.prog_resize_inc and
        size_hints.width_inc == incr_size.w and
        size_hints.height_inc == incr_size.h)
        return;

    size_hints.flags.prog_resize_inc = true;
    size_hints.width_inc = incr_size.w;
    size_hints.height_inc = incr_size.h;

    try check(c.xcb_change_property_checked(
        xcb.conn,
        c.XCB_PROP_MODE_REPLACE,
        @intCast(wind.id),
        c.XCB_ATOM_WM_NORMAL_HINTS,
        c.XCB_ATOM_WM_SIZE_HINTS,
        @bitSizeOf(i32),
        @sizeOf(SizeHints) / @sizeOf(i32),
        size_hints,
    ));
    try tryFlush();
}

pub fn setWindowAspect(wind: *windy.Window, numerator: u16, denominator: u16) !void {
    var size_hints = &wind.platform.size_hints;
    if (size_hints.flags.prog_aspect and
        // only need to check `min_aspect` here since it's set in tandem with `max_aspect`
        size_hints.min_aspect.numerator == numerator and
        size_hints.min_aspect.denominator == denominator)
        return;

    size_hints.flags.prog_aspect = true;
    size_hints.min_aspect.numerator = numerator;
    size_hints.min_aspect.denominator = denominator;
    size_hints.max_aspect.numerator = numerator;
    size_hints.max_aspect.denominator = denominator;

    try check(c.xcb_change_property_checked(
        xcb.conn,
        c.XCB_PROP_MODE_REPLACE,
        @intCast(wind.id),
        c.XCB_ATOM_WM_NORMAL_HINTS,
        c.XCB_ATOM_WM_SIZE_HINTS,
        @bitSizeOf(i32),
        @sizeOf(SizeHints) / @sizeOf(i32),
        size_hints,
    ));
    try tryFlush();
}

pub fn resizeWindow(wind: windy.Window, size: windy.Size) !void {
    const vals = [_]u32{ size.w, size.h };
    try check(c.xcb_configure_window_checked(
        xcb.conn,
        @as(u32, @intCast(wind.id)),
        c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT,
        &vals,
    ));
    try tryFlush();
}

pub fn moveWindow(wind: windy.Window, pos: windy.Position) !void {
    if (pos.x < 0 or pos.y < 0) return error.InvalidPosition;
    const vals = [_]u32{ @intCast(pos.x), @intCast(pos.y) };
    try check(c.xcb_configure_window_checked(
        xcb.conn,
        @as(u32, @intCast(wind.id)),
        c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y,
        &vals,
    ));
    try tryFlush();
}

pub fn registerRefreshCb(wind: *windy.Window, add: bool) !void {
    try registerEventMask(wind, c.XCB_EVENT_MASK_EXPOSURE, add);
}

pub fn registerConfigure(wind: *windy.Window, add: bool) !void {
    try registerEventMask(wind, c.XCB_EVENT_MASK_STRUCTURE_NOTIFY, add);
}

pub fn registerKeyCb(wind: *windy.Window, add: bool) !void {
    try registerEventMask(wind, c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_KEY_RELEASE, add);
}

pub fn registerMouseCb(wind: *windy.Window, add: bool) !void {
    try registerEventMask(wind, c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE, add);
}

pub fn registerMouseMoveCb(wind: *windy.Window, add: bool) !void {
    try registerEventMask(wind, c.XCB_EVENT_MASK_POINTER_MOTION | c.XCB_EVENT_MASK_BUTTON_MOTION, add);
}

pub fn registerScrollCb(wind: *windy.Window, add: bool) !void {
    try registerEventMask(wind, c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE, add);
}

fn atom(name: [:0]const u8) !c.xcb_atom_t {
    const cookie = c.xcb_intern_atom(xcb.conn, 0, @intCast(name.len), name.ptr);
    const reply = c.xcb_intern_atom_reply(xcb.conn, cookie, null) orelse return error.OutOfMemory;
    defer std.c.free(reply);
    return reply.*.atom;
}

fn registerEventMask(wind: *windy.Window, mask: i32, add: bool) !void {
    if (wind.platform.event_mask_list & mask != 0 or !add)
        return;

    if (add)
        wind.platform.event_mask_list |= mask
    else
        wind.platform.event_mask_list &= ~mask;

    const vals = [_]u32{@intCast(wind.platform.event_mask_list)};
    try check(c.xcb_change_window_attributes_checked(
        xcb.conn,
        @as(u32, @intCast(wind.id)),
        c.XCB_CW_EVENT_MASK,
        &vals,
    ));
    try tryFlush();
}

fn updateKeymaps() !void {
    c.xkb_keymap_unref(xkb.keymap);
    c.xkb_state_unref(xkb.state);
    xkb.keymap = c.xkb_x11_keymap_new_from_device(
        xkb.ctx,
        xcb.conn,
        xkb.core_dvid,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.InvalidKeymap;
    errdefer c.xkb_keymap_unref(xkb.keymap);
    xkb.state = c.xkb_x11_state_new_from_device(
        xkb.keymap,
        xcb.conn,
        xkb.core_dvid,
    ) orelse return error.InvalidKeyState;
}

// Key and mouse masks overlap
fn toMods(state: u16) windy.Mods {
    return .{
        .shift = state & c.XCB_MOD_MASK_SHIFT != 0,
        .caps_lock = state & c.XCB_MOD_MASK_LOCK != 0,
        .ctrl = state & c.XCB_MOD_MASK_CONTROL != 0,
        .alt = state & c.XCB_MOD_MASK_1 != 0,
        .num_lock = state & c.XCB_MOD_MASK_2 != 0,
        .super = state & c.XCB_MOD_MASK_3 != 0,
    };
}

fn symToKey(sym: c.xkb_keysym_t) windy.Key {
    return switch (sym) {
        c.XKB_KEY_0 => .zero,
        c.XKB_KEY_1 => .one,
        c.XKB_KEY_2 => .two,
        c.XKB_KEY_3 => .three,
        c.XKB_KEY_4 => .four,
        c.XKB_KEY_5 => .five,
        c.XKB_KEY_6 => .six,
        c.XKB_KEY_7 => .seven,
        c.XKB_KEY_8 => .eight,
        c.XKB_KEY_9 => .nine,
        c.XKB_KEY_A, c.XKB_KEY_a => .a,
        c.XKB_KEY_B, c.XKB_KEY_b => .b,
        c.XKB_KEY_C, c.XKB_KEY_c => .c,
        c.XKB_KEY_D, c.XKB_KEY_d => .d,
        c.XKB_KEY_E, c.XKB_KEY_e => .e,
        c.XKB_KEY_F, c.XKB_KEY_f => .f,
        c.XKB_KEY_G, c.XKB_KEY_g => .g,
        c.XKB_KEY_H, c.XKB_KEY_h => .h,
        c.XKB_KEY_I, c.XKB_KEY_i => .i,
        c.XKB_KEY_J, c.XKB_KEY_j => .j,
        c.XKB_KEY_K, c.XKB_KEY_k => .k,
        c.XKB_KEY_L, c.XKB_KEY_l => .l,
        c.XKB_KEY_M, c.XKB_KEY_m => .m,
        c.XKB_KEY_N, c.XKB_KEY_n => .n,
        c.XKB_KEY_O, c.XKB_KEY_o => .o,
        c.XKB_KEY_P, c.XKB_KEY_p => .p,
        c.XKB_KEY_Q, c.XKB_KEY_q => .q,
        c.XKB_KEY_R, c.XKB_KEY_r => .r,
        c.XKB_KEY_S, c.XKB_KEY_s => .s,
        c.XKB_KEY_T, c.XKB_KEY_t => .t,
        c.XKB_KEY_U, c.XKB_KEY_u => .u,
        c.XKB_KEY_V, c.XKB_KEY_v => .v,
        c.XKB_KEY_W, c.XKB_KEY_w => .w,
        c.XKB_KEY_X, c.XKB_KEY_x => .x,
        c.XKB_KEY_Y, c.XKB_KEY_y => .y,
        c.XKB_KEY_Z, c.XKB_KEY_z => .z,
        c.XKB_KEY_F1 => .f1,
        c.XKB_KEY_F2 => .f2,
        c.XKB_KEY_F3 => .f3,
        c.XKB_KEY_F4 => .f4,
        c.XKB_KEY_F5 => .f5,
        c.XKB_KEY_F6 => .f6,
        c.XKB_KEY_F7 => .f7,
        c.XKB_KEY_F8 => .f8,
        c.XKB_KEY_F9 => .f9,
        c.XKB_KEY_F10 => .f10,
        c.XKB_KEY_F11 => .f11,
        c.XKB_KEY_F12 => .f12,
        c.XKB_KEY_F13 => .f13,
        c.XKB_KEY_F14 => .f14,
        c.XKB_KEY_F15 => .f15,
        c.XKB_KEY_F16 => .f16,
        c.XKB_KEY_F17 => .f17,
        c.XKB_KEY_F18 => .f18,
        c.XKB_KEY_F19 => .f19,
        c.XKB_KEY_F20 => .f20,
        c.XKB_KEY_F21 => .f21,
        c.XKB_KEY_F22 => .f22,
        c.XKB_KEY_F23 => .f23,
        c.XKB_KEY_F24 => .f24,
        c.XKB_KEY_F25 => .f25,
        c.XKB_KEY_KP_0 => .kp_0,
        c.XKB_KEY_KP_1 => .kp_1,
        c.XKB_KEY_KP_2 => .kp_2,
        c.XKB_KEY_KP_3 => .kp_3,
        c.XKB_KEY_KP_4 => .kp_4,
        c.XKB_KEY_KP_5 => .kp_5,
        c.XKB_KEY_KP_6 => .kp_6,
        c.XKB_KEY_KP_7 => .kp_7,
        c.XKB_KEY_KP_8 => .kp_8,
        c.XKB_KEY_KP_9 => .kp_9,
        c.XKB_KEY_KP_Divide => .kp_divide,
        c.XKB_KEY_KP_Multiply => .kp_multiply,
        c.XKB_KEY_KP_Subtract => .kp_subtract,
        c.XKB_KEY_KP_Add => .kp_add,
        c.XKB_KEY_KP_Decimal, c.XKB_KEY_KP_Separator => .kp_decimal,
        c.XKB_KEY_KP_Equal => .kp_equal,
        c.XKB_KEY_KP_Enter => .kp_enter,
        c.XKB_KEY_Shift_L => .left_shift,
        c.XKB_KEY_Shift_R => .right_shift,
        c.XKB_KEY_Control_L => .left_control,
        c.XKB_KEY_Control_R => .right_control,
        c.XKB_KEY_Alt_L, c.XKB_KEY_Meta_L => .left_alt,
        c.XKB_KEY_Alt_R, c.XKB_KEY_Meta_R, c.XKB_KEY_Mode_switch, c.XKB_KEY_ISO_Level3_Shift => .right_alt,
        c.XKB_KEY_Super_L => .left_super,
        c.XKB_KEY_Super_R => .right_super,
        c.XKB_KEY_bracketleft => .left_bracket,
        c.XKB_KEY_bracketright => .right_bracket,
        c.XKB_KEY_less => .less_than,
        c.XKB_KEY_greater => .greater_than,
        c.XKB_KEY_Num_Lock => .num_lock,
        c.XKB_KEY_Caps_Lock => .caps_lock,
        c.XKB_KEY_Scroll_Lock => .scroll_lock,
        c.XKB_KEY_Page_Up, c.XKB_KEY_KP_Page_Up => .page_up,
        c.XKB_KEY_Page_Down, c.XKB_KEY_KP_Page_Down => .page_down,
        c.XKB_KEY_Left => .left,
        c.XKB_KEY_Right => .right,
        c.XKB_KEY_Up => .up,
        c.XKB_KEY_Down => .down,
        c.XKB_KEY_minus => .minus,
        c.XKB_KEY_equal => .equal,
        c.XKB_KEY_Return => .enter,
        c.XKB_KEY_Escape => .escape,
        c.XKB_KEY_Tab => .tab,
        c.XKB_KEY_BackSpace => .backspace,
        c.XKB_KEY_semicolon => .semicolon,
        c.XKB_KEY_apostrophe => .apostrophe,
        c.XKB_KEY_comma => .comma,
        c.XKB_KEY_period => .period,
        c.XKB_KEY_grave => .grave_accent,
        c.XKB_KEY_backslash => .backslash,
        c.XKB_KEY_slash => .slash,
        c.XKB_KEY_Pause => .pause,
        c.XKB_KEY_Delete => .delete,
        c.XKB_KEY_Home => .home,
        c.XKB_KEY_End => .end,
        c.XKB_KEY_Insert => .insert,
        c.XKB_KEY_Menu => .menu,
        c.XKB_KEY_Print => .print,
        else => .invalid,
    };
}

fn buttonToMouse(button: u8) windy.MouseButton {
    return switch (button) {
        1...3 => @enumFromInt(button - 1),
        8...36 => @enumFromInt(button - 5),
        else => .invalid,
    };
}

inline fn tryFlush() !void {
    const flush = c.xcb_flush(xcb.conn);
    if (flush >= 0) return;
    std.log.err("Received error code `{}` during cursor set flush", .{flush});
    return error.Flush;
}

inline fn processConnErr(errcode: i32) !void {
    return switch (errcode) {
        0 => {},
        c.XCB_CONN_ERROR => return error.Connection,
        c.XCB_CONN_CLOSED_EXT_NOTSUPPORTED => return error.ExtUnsupported,
        c.XCB_CONN_CLOSED_MEM_INSUFFICIENT => return error.OutOfMemory,
        c.XCB_CONN_CLOSED_REQ_LEN_EXCEED => return error.ReqLenExceed,
        c.XCB_CONN_CLOSED_PARSE_ERR => return error.Parse,
        c.XCB_CONN_CLOSED_INVALID_SCREEN => return error.InvalidScreen,
        c.XCB_CONN_CLOSED_FDPASSING_FAILED => return error.FdPass,
        else => return error.Unknown,
    };
}

inline fn processErr(err: [*c]c.xcb_generic_error_t) !void {
    return switch (err.*.error_code) {
        c.XCB_REQUEST => {
            const e: *c.xcb_request_error_t = @ptrCast(err);
            std.log.err("Request error: {}", .{e});
            return error.Request;
        },
        c.XCB_VALUE => {
            const e: *c.xcb_value_error_t = @ptrCast(err);
            std.log.err("Value error: {}", .{e});
            return error.Value;
        },
        c.XCB_WINDOW => {
            const e: *c.xcb_window_error_t = @ptrCast(err);
            std.log.err("Window error: {}", .{e});
            return error.Window;
        },
        c.XCB_PIXMAP => {
            const e: *c.xcb_pixmap_error_t = @ptrCast(err);
            std.log.err("Pixmap error: {}", .{e});
            return error.Pixmap;
        },
        c.XCB_ATOM => {
            const e: *c.xcb_atom_error_t = @ptrCast(err);
            std.log.err("Atom error: {}", .{e});
            return error.Atom;
        },
        c.XCB_CURSOR => {
            const e: *c.xcb_cursor_error_t = @ptrCast(err);
            std.log.err("Cursor error: {}", .{e});
            return error.Cursor;
        },
        c.XCB_FONT => {
            const e: *c.xcb_font_error_t = @ptrCast(err);
            std.log.err("Font error: {}", .{e});
            return error.Font;
        },
        c.XCB_MATCH => {
            const e: *c.xcb_match_error_t = @ptrCast(err);
            std.log.err("Match error: {}", .{e});
            return error.Match;
        },
        c.XCB_DRAWABLE => {
            const e: *c.xcb_drawable_error_t = @ptrCast(err);
            std.log.err("Drawable error: {}", .{e});
            return error.Drawable;
        },
        c.XCB_ACCESS => {
            const e: *c.xcb_access_error_t = @ptrCast(err);
            std.log.err("Access error: {}", .{e});
            return error.Access;
        },
        c.XCB_ALLOC => {
            const e: *c.xcb_alloc_error_t = @ptrCast(err);
            std.log.err("Alloc error: {}", .{e});
            return error.OutOfMemory; // diverges so it can unify with other OOM
        },
        c.XCB_COLORMAP => {
            const e: *c.xcb_colormap_error_t = @ptrCast(err);
            std.log.err("Colormap error: {}", .{e});
            return error.Colormap;
        },
        c.XCB_G_CONTEXT => {
            const e: *c.xcb_g_context_error_t = @ptrCast(err);
            std.log.err("Graphics context error: {}", .{e});
            return error.GraphicsContext;
        },
        c.XCB_ID_CHOICE => {
            const e: *c.xcb_id_choice_error_t = @ptrCast(err);
            std.log.err("Id choice error: {}", .{e});
            return error.IdChoice;
        },
        c.XCB_NAME => {
            const e: *c.xcb_name_error_t = @ptrCast(err);
            std.log.err("Name error: {}", .{e});
            return error.Name;
        },
        c.XCB_LENGTH => {
            const e: *c.xcb_length_error_t = @ptrCast(err);
            std.log.err("Length error: {}", .{e});
            return error.Length;
        },
        c.XCB_IMPLEMENTATION => {
            const e: *c.xcb_implementation_error_t = @ptrCast(err);
            std.log.err("Implementation error: {}", .{e});
            return error.Implementation;
        },
        else => {
            std.log.err("Unknown error: {}", .{err.*});
            return error.Unknown;
        },
    };
}

inline fn check(cookie: c.xcb_void_cookie_t) !void {
    if (c.xcb_request_check(xcb.conn, cookie)) |err|
        try processErr(err);
}
