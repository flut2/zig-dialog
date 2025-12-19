## zig-dialog
Cross-platform dialog library in Zig (work in progress)

An example implementation can be found over at `./example`.

Supported dialog types:
- Various file choosers (single/multiple file/directory open, file save)
- Info, warning and error message dialogs

Supported OSes:
- Linux / BSDs: GTK3 (requires dev headers), Zenity (requires Zenity to be present on the user's computer)
- Windows