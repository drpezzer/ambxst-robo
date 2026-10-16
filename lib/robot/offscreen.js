// Port only: the browser's off-screen <canvas> for robot-heads' renderer
// (render.ts makeCanvas), on Qt Quick. QML can't make a canvas from script, so
// every OffCanvas draws on ONE hidden scratch Canvas (Robo.qml) and keeps its
// pixels as an ImageData snapshot; whichever canvas draws next swaps its own
// pixels in. Drawn elsewhere (drawImage, createPattern), a canvas hands over its
// snapshot (CtxWrap.drawImage takes `__qmlImage`).
import { CtxWrap } from "../shims.js";

let scratch = null; // { q: the scratch Context2D, w, h }
let owner = null;

/** The host's scratch canvas: Context2D and size (Robo.qml). */
export function setScratch(q, w, h) {
  scratch = { q, w, h };
  owner = null;
}
export function hasScratch() { return scratch !== null; }

/**
 * The scratch, made by the host beside the canvas about to draw a robot
 * (Robo.qml robotScratch: a Canvas has a context only inside a window). It
 * goes with that window (the tab unloads with the notch): made again, then.
 */
export function ensureScratch(ctxWrap) {
  if (scratch && scratch.alive && !scratch.alive()) { scratch = null; owner = null; }
  if (scratch) return true;
  if (typeof __host === "undefined" || !__host.robotScratch) return false;
  const s = __host.robotScratch(ctxWrap && ctxWrap.canvas);
  if (!s) return false;
  setScratch(s.ctx, s.w, s.h);
  scratch.alive = s.alive;
  return true;
}

function claim(c) {
  if (owner === c) return;
  const q = scratch.q;
  // A snapshot only when it was drawn on since the last one: each one is a
  // native pixel buffer the GC doesn't count, so they must stay rare.
  if (owner && owner._dirty) {
    owner._snap = q.getImageData(0, 0, owner.width, owner.height);
    owner._dirty = false;
  }
  owner = c;
  // Everything the last canvas left (clip included: a clip left set made the
  // clear miss and leaked one canvas into the next) goes, pixels too.
  q.reset();
  // (Qt's putImageData needs the 7-argument form, see shims.js.)
  if (c._snap) q.putImageData(c._snap, 0, 0, 0, 0, c._snap.width, c._snap.height);
  // Its own transform comes back with it.
  const m = c._ctx ? c._ctx.m : null;
  if (m) q.setTransform(m.a, m.b, m.c, m.d, m.e, m.f);
}

class OffCtx extends CtxWrap {
  constructor(c) {
    super(null, c);
    this._c = c;
  }
}
// Always the scratch of now: it is made again when its window goes (the tab
// unloading), and a context holding the old one drew into a dead canvas.
Object.defineProperty(OffCtx.prototype, "q", {
  get() { return scratch ? scratch.q : null; },
  set(v) {},
  configurable: true,
});
// Every drawing call (and state write) claims the scratch for its canvas first.
for (const name of Object.getOwnPropertyNames(CtxWrap.prototype)) {
  if (name === "constructor" || name === "q") continue;
  const d = Object.getOwnPropertyDescriptor(CtxWrap.prototype, name);
  if (typeof d.value === "function") {
    Object.defineProperty(OffCtx.prototype, name, {
      value: function (...a) { claim(this._c); this._c._dirty = true; return d.value.apply(this, a); },
      writable: true, configurable: true,
    });
  } else if (d.set || d.get) {
    Object.defineProperty(OffCtx.prototype, name, {
      get: d.get ? function () { claim(this._c); return d.get.call(this); } : undefined,
      set: d.set ? function (v) { claim(this._c); d.set.call(this, v); } : undefined,
      configurable: true,
    });
  }
}

export class OffCanvas {
  constructor(w, h) {
    this.width = Math.max(1, Math.ceil(w));
    this.height = Math.max(1, Math.ceil(h));
    if (scratch && (this.width > scratch.w || this.height > scratch.h)) {
      // Bigger than the scratch: drawn cut off (the scratch is sized for the island's mascot).
      this.width = Math.min(this.width, scratch.w);
      this.height = Math.min(this.height, scratch.h);
    }
    this._snap = null;
    this._ctx = null;
    this._dirty = false;
  }
  getContext() {
    if (!this._ctx) this._ctx = new OffCtx(this);
    return this._ctx;
  }
  /** Its pixels, for drawImage / createPattern elsewhere. */
  get __qmlImage() {
    if (owner === this && this._dirty) {
      this._snap = scratch.q.getImageData(0, 0, this.width, this.height);
      this._dirty = false;
    }
    if (!this._snap) this._snap = scratch.q.createImageData(this.width, this.height);
    return this._snap;
  }
}
