// Globals the browser code expects, mapped onto the QML JS host. `__host` is
// filled in by Robo.qml before start() (invoke, listen, timers, sound...).
var __host = {
  setTimeout: null, clearTimeout: null, invoke: null, listen: null, emitTo: null,
  sound: { load: function () {}, play: function () {}, fadeOut: function () {} },
  storage: {}, saveStorage: function () {}, languages: ["en"], windowLabel: "main",
};
var performance = { now: function () { return Date.now(); } };
var setTimeout = function (f, ms) { return __host.setTimeout ? __host.setTimeout(f, ms || 0) : 0; };
var clearTimeout = function (id) { if (id != null && __host.clearTimeout) __host.clearTimeout(id); };
var setInterval = function (f, ms) { return __host.setInterval ? __host.setInterval(f, ms || 0) : 0; };
var clearInterval = function (id) { if (id != null && __host.clearInterval) __host.clearInterval(id); };
var requestAnimationFrame = function (f) { return setTimeout(function () { f(performance.now()); }, 16); };
var __winListeners = {};
var localStorage = {
  getItem: function (k) { return Object.prototype.hasOwnProperty.call(__host.storage, k) ? __host.storage[k] : null; },
  setItem: function (k, v) { __host.storage[k] = String(v); __host.saveStorage(); },
  removeItem: function (k) { delete __host.storage[k]; __host.saveStorage(); },
};
var window = {
  setTimeout: setTimeout, clearTimeout: clearTimeout, setInterval: setInterval, clearInterval: clearInterval,
  devicePixelRatio: 1, localStorage: localStorage, __TAURI_INTERNALS__: {},
  addEventListener: function (type, fn) { (__winListeners[type] = __winListeners[type] || []).push(fn); },
  removeEventListener: function (type, fn) {
    var l = __winListeners[type]; if (!l) return; var i = l.indexOf(fn); if (i >= 0) l.splice(i, 1);
  },
  dispatch: function (type, ev) { (__winListeners[type] || []).slice().forEach(function (fn) { fn(ev); }); },
};
var navigator = { get languages() { return __host.languages; }, get language() { return __host.languages[0]; }, userAgent: "Linux" };
var document = { documentElement: null, createElement: function () { return { getContext: function () { return null; }, style: {} }; } };
// Web APIs V4 lacks.
var TextEncoder = function () {};
TextEncoder.prototype.encode = function (s) {
  var out = [];
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) {
      var d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
    }
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return new Uint8Array(out);
};
var URL = function (raw) {
  var m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/(?:([^:@\/?#]*)(?::([^@\/?#]*))?@)?(\[[^\]]*\]|[^:\/?#]*)(?::(\d*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(String(raw));
  if (!m) throw new TypeError("Invalid URL: " + raw);
  this.protocol = m[1].toLowerCase();
  this.username = m[2] || ""; this.password = m[3] || "";
  this.hostname = (m[4] || "").toLowerCase(); this.port = m[5] || "";
  if (!this.hostname) throw new TypeError("Invalid URL: " + raw);
  this.host = this.hostname + (this.port ? ":" + this.port : "");
  this.pathname = m[6] || "/"; this.search = m[7] || ""; this.hash = m[8] || "";
  this.origin = this.protocol + "//" + this.host;
  this.href = this.origin + this.pathname + this.search + this.hash;
};
URL.prototype.toString = function () { return this.href; };
// ES2017+ library functions V4 lacks (esbuild lowers syntax, not the library).
(function () {
  function def(o, k, v) { if (!o[k]) Object.defineProperty(o, k, { value: v, writable: true, configurable: true }); }
  def(Object, "fromEntries", function (it) { var o = {}; Array.from(it).forEach(function (e) { o[e[0]] = e[1]; }); return o; });
  def(Object, "entries", function (o) { return Object.keys(o).map(function (k) { return [k, o[k]]; }); });
  def(Object, "values", function (o) { return Object.keys(o).map(function (k) { return o[k]; }); });
  def(Object, "hasOwn", function (o, k) { return Object.prototype.hasOwnProperty.call(o, k); });
  def(Array.prototype, "flat", function (d) {
    d = d === undefined ? 1 : d;
    return this.reduce(function (a, v) { return a.concat(Array.isArray(v) && d > 0 ? v.flat(d - 1) : [v]); }, []);
  });
  def(Array.prototype, "flatMap", function (f, t) { return this.map(f, t).flat(1); });
  def(Array.prototype, "at", function (i) { i = Math.trunc(i) || 0; if (i < 0) i += this.length; return this[i]; });
  def(Array.prototype, "findLast", function (f) { for (var i = this.length - 1; i >= 0; i--) if (f(this[i], i, this)) return this[i]; });
  def(Array.prototype, "findLastIndex", function (f) { for (var i = this.length - 1; i >= 0; i--) if (f(this[i], i, this)) return i; return -1; });
  def(Array.prototype, "includes", function (v) { return this.indexOf(v) >= 0 || (v !== v && this.some(function (x) { return x !== x; })); });
  def(String.prototype, "at", function (i) { i = Math.trunc(i) || 0; if (i < 0) i += this.length; return this.charAt(i) || undefined; });
  def(String.prototype, "trimStart", function () { return this.replace(/^\s+/, ""); });
  def(String.prototype, "trimEnd", function () { return this.replace(/\s+$/, ""); });
  def(String.prototype, "padStart", function (n, s) { s = s === undefined ? " " : String(s); var t = String(this); while (t.length < n) t = s + t; return t.slice(t.length - Math.max(n, this.length)); });
  def(String.prototype, "padEnd", function (n, s) { s = s === undefined ? " " : String(s); var t = String(this); while (t.length < n) t = t + s; return t.slice(0, Math.max(n, this.length)); });
  def(String.prototype, "replaceAll", function (a, b) {
    if (a instanceof RegExp) return this.replace(a, b);
    return this.split(a).join(typeof b === "function" ? b(a) : b);
  });
  def(String.prototype, "matchAll", function (re) {
    var r = new RegExp(re.source, re.flags.indexOf("g") >= 0 ? re.flags : re.flags + "g"), m, out = [];
    while ((m = r.exec(this)) !== null) { out.push(m); if (m[0] === "") r.lastIndex++; }
    return out[Symbol.iterator]();
  });
  def(Promise, "allSettled", function (ps) {
    return Promise.all(Array.from(ps).map(function (p) {
      return Promise.resolve(p).then(function (v) { return { status: "fulfilled", value: v }; },
        function (e) { return { status: "rejected", reason: e }; });
    }));
  });
  def(Promise.prototype, "finally", function (f) {
    return this.then(function (v) { return Promise.resolve(f()).then(function () { return v; }); },
      function (e) { return Promise.resolve(f()).then(function () { throw e; }); });
  });
})();
var globalThis = (function () { return this; })() || {};
var queueMicrotask = function (f) { Promise.resolve().then(f); };
var structuredClone = function (v) { return v === undefined ? v : JSON.parse(JSON.stringify(v)); };
// Key events from QML into the window listeners upstream registered
// (capture-phase listeners first, as they were added with `true`).
var __dispatchWindowEvent = function (type, ev, isStopped) {
  var l = (__winListeners[type] || []).slice();
  for (var i = 0; i < l.length; i++) { l[i](ev); if (isStopped && isStopped()) break; }
};
