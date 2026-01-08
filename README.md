## Windy
Cross-platform windowing library.

An example implementation can be found over at `./example`.

Supported features:
- Windows
- Input
- Clipboard
- Cursors
- Vulkan WSI (use `-Dvulkan_support=true`, example implementation over at [Eclipse](https://github.com/flut2/eclipse/tree/windy))
- Dialogs (file, color, message)

Supported OSes:
- Linux / BSDs:
    - X11 (requires `xcb`, `xcb-xkb`, `xcb-render`, `xcb-render-util` and `xkbcommon-x11` to build)
    - Dialog notes: either GTK3 (requires dev headers) or Zenity, `-Duse_gtk={}` to change
- Windows