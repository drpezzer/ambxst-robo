// @tauri-apps/api/event for the QML host.
export function listen(name, cb) {
  var off = __host.listen(name, function (payload) { cb({ event: name, payload: payload, id: 0 }); });
  return Promise.resolve(off);
}
export function once(name, cb) {
  var off = null;
  off = __host.listen(name, function (payload) { if (off) off(); cb({ event: name, payload: payload, id: 0 }); });
  return Promise.resolve(off);
}
export function emit(name, payload) { __host.emitTo(null, name, payload); return Promise.resolve(); }
export function emitTo(target, name, payload) { __host.emitTo(target, name, payload); return Promise.resolve(); }
