const std = @import("std");

const stbi = @import("stbi");
const windy = @import("windy");

fn resizeCb(_: *windy.Window, w: u16, h: u16) void {
    std.log.info("Resized to {}x{}", .{ w, h });
}

fn moveCb(_: *windy.Window, x: i16, y: i16) void {
    std.log.info("Moved to x={} y={}", .{ x, y });
}

fn keyCb(_: *windy.Window, state: windy.PressState, key: windy.Key, mods: windy.Mods) void {
    std.log.info("Key {} {}, mods: {}", .{ key, state, mods });
}

fn charCb(_: *windy.Window, char: u21, mods: windy.Mods) void {
    std.log.info("Char {u} pressed, mods: {}", .{ char, mods });
}

fn mouseCb(_: *windy.Window, state: windy.PressState, mouse: windy.MouseButton, x: i16, y: i16, mods: windy.Mods) void {
    std.log.info("Mouse {} {} at x={} y={}, mods: {}", .{ mouse, state, x, y, mods });
}

fn scrollCb(_: *windy.Window, delta_x: f32, delta_y: f32, mods: windy.Mods) void {
    std.log.info("Mouse scroll with x={} y={}, mods: {}", .{ delta_x, delta_y, mods });
}

pub fn main() !void {
    var dbg_alloc: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator = dbg_alloc.allocator();

    stbi.init(allocator);
    defer stbi.deinit();

    var cursor_image: stbi.Image = try .loadFromMemory(@embedFile("cursor.png"), 4);
    defer cursor_image.deinit();
    if (cursor_image.width > std.math.maxInt(u16) or cursor_image.height > std.math.maxInt(u16))
        return error.CursorTooLarge;

    const clip_buf = try allocator.alloc(u8, std.math.maxInt(u12));
    defer allocator.free(clip_buf);
    try windy.init(allocator, clip_buf);
    defer windy.deinit();

    const wind: *windy.Window = try .create(1280, 720, .{
        .back_pixel = .black,
        .title = "Example Window",
    });
    defer wind.destroy();

    try wind.setMinSize(.{ .w = 1280, .h = 720 });
    try wind.setResizeIncr(.{ .w = 4, .h = 3 });

    // Convert from little endian ABGR to ARGB, as that's the required cursor format
    for (0..cursor_image.data.len / 4) |i|
        std.mem.swap(u8, &cursor_image.data[i * 4], &cursor_image.data[i * 4 + 2]);

    const cursor: windy.Cursor = try .create(
        cursor_image.data,
        @intCast(cursor_image.width),
        @intCast(cursor_image.height),
        0,
        0,
    );
    defer cursor.destroy();

    try wind.setCursor(cursor);

    try wind.registerResizeCb(resizeCb);
    try wind.registerMoveCb(moveCb);
    try wind.registerKeyCb(keyCb);
    try wind.registerCharCb(charCb);
    try wind.registerMouseCb(mouseCb);
    try wind.registerScrollCb(scrollCb);

    while (!wind.should_close) {
        try windy.pollEvents();
        const clip = try windy.getClipboard();
        if (clip.len > 0) {
            std.log.info("Clipboard received: {s}", .{clip});
            try windy.setClipboard(&.{});
        }
    }
}
