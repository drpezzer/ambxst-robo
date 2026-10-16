// @tauri-apps/api/core for the QML host: invoke() goes to __host.invoke,
// which answers window commands itself and sends the rest to ambxst-robo.
export function invoke(cmd, args) {
  return new Promise(function (resolve, reject) {
    __host.invoke(cmd, args || {}, resolve, reject);
  });
}
export function convertFileSrc(p) { return "file://" + p; }
export function isTauri() { return true; }
