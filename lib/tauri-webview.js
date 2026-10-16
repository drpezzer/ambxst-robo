// @tauri-apps/api/webview and /window for the QML host: drag-and-drop comes
// from QML DropAreas through the "file-drag" event instead.
function handle() {
  return {
    label: __host.windowLabel || "main",
    onDragDropEvent: function (cb) {
      var off = __host.listen("file-drag", function (p) { cb({ payload: p }); });
      return Promise.resolve(off);
    },
    listen: function (name, cb) { return Promise.resolve(__host.listen(name, function (p) { cb({ payload: p }); })); },
  };
}
export function getCurrentWebview() { return handle(); }
export function getCurrentWindow() { return handle(); }
export function getCurrentWebviewWindow() { return handle(); }
