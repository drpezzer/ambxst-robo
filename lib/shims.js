// HTML canvas features Qt Quick's Context2D lacks, provided to the bundled
// Coucou code. Path2D records commands; CtxWrap replays them on the real
// QML context at fill/stroke/clip time (HTML semantics: the path is mapped
// by the transform current at that moment).
export class Path2D {
  constructor(p) { this.ops = p && p.ops ? p.ops.slice() : []; }
  moveTo(...a) { this.ops.push(["moveTo", a]); }
  lineTo(...a) { this.ops.push(["lineTo", a]); }
  quadraticCurveTo(...a) { this.ops.push(["quadraticCurveTo", a]); }
  bezierCurveTo(...a) { this.ops.push(["bezierCurveTo", a]); }
  arc(...a) { this.ops.push(["arc", a]); }
  arcTo(...a) { this.ops.push(["arcTo", a]); }
  ellipse(...a) { this.ops.push(["ellipse", a]); }
  rect(...a) { this.ops.push(["rect", a]); }
  roundRect(...a) { this.ops.push(["roundRect", a]); }
  closePath() { this.ops.push(["closePath", []]); }
  addPath(p) { this.ops.push(...p.ops); }
}

// Matrix helpers for getTransform / setTransform bookkeeping.
const I = () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 });
const mul = (m, n) => ({
  a: m.a * n.a + m.c * n.b, b: m.b * n.a + m.d * n.b,
  c: m.a * n.c + m.c * n.d, d: m.b * n.c + m.d * n.d,
  e: m.a * n.e + m.c * n.f + m.e, f: m.b * n.e + m.d * n.f + m.f,
});

export class CtxWrap {
  constructor(ctx, canvas) {
    this.q = ctx; this.canvas = canvas || { width: 0, height: 0 };
    this.m = I(); this.stack = [];
    this._dash = []; this._dashOffset = 0; this._shadow = null; this._filter = "none";
    this.__layer = null; // outfits.ts withLayer's scratch canvas (Robo.qml layerCanvas)
    // Port (robot-heads): plain data, nothing in Qt to switch (Qt smooths
    // scaled images anyway). An accessor here made V4 throw "Type error" on
    // the assignment, now and then, which cut the robot's frame short.
    this.imageSmoothingEnabled = true;
    this.imageSmoothingQuality = "high";
  }
  // state
  save() { this.stack.push(this.m); this.q.save(); }
  restore() { if (this.stack.length) this.m = this.stack.pop(); this.q.restore(); }
  translate(x, y) { this.m = mul(this.m, { a: 1, b: 0, c: 0, d: 1, e: x, f: y }); this.q.translate(x, y); }
  scale(x, y) { this.m = mul(this.m, { a: x, b: 0, c: 0, d: y, e: 0, f: 0 }); this.q.scale(x, y); }
  rotate(r) { const c = Math.cos(r), s = Math.sin(r); this.m = mul(this.m, { a: c, b: s, c: -s, d: c, e: 0, f: 0 }); this.q.rotate(r); }
  transform(a, b, c, d, e, f) { this.m = mul(this.m, { a, b, c, d, e, f }); this.q.transform(a, b, c, d, e, f); }
  setTransform(a, b, c, d, e, f) {
    if (typeof a === "object") ({ a, b, c, d, e, f } = a);
    this.m = { a, b, c, d, e, f }; this.q.setTransform(a, b, c, d, e, f);
  }
  resetTransform() { this.setTransform(1, 0, 0, 1, 0, 0); }
  getTransform() { const m = this.m; return { a: m.a, b: m.b, c: m.c, d: m.d, e: m.e, f: m.f, inverse() {
    const det = m.a * m.d - m.b * m.c;
    return { a: m.d / det, b: -m.b / det, c: -m.c / det, d: m.a / det,
      e: (m.c * m.f - m.d * m.e) / det, f: (m.b * m.e - m.a * m.f) / det };
  } }; }
  // properties
  get fillStyle() { return this.q.fillStyle; } set fillStyle(v) { this.q.fillStyle = v; }
  get strokeStyle() { return this.q.strokeStyle; } set strokeStyle(v) { this.q.strokeStyle = v; }
  get lineWidth() { return this.q.lineWidth; } set lineWidth(v) { this.q.lineWidth = v; }
  get lineCap() { return this.q.lineCap; } set lineCap(v) { this.q.lineCap = v; }
  get lineJoin() { return this.q.lineJoin; } set lineJoin(v) { this.q.lineJoin = v; }
  get globalAlpha() { return this.q.globalAlpha; } set globalAlpha(v) { this.q.globalAlpha = v; }
  get globalCompositeOperation() { return this.q.globalCompositeOperation; } set globalCompositeOperation(v) { this.q.globalCompositeOperation = v; }
  get font() { return this.q.font; } set font(v) { this.q.font = v; }
  get textAlign() { return this.q.textAlign; } set textAlign(v) { this.q.textAlign = v; }
  get textBaseline() { return this.q.textBaseline; } set textBaseline(v) { this.q.textBaseline = v; }
  get shadowBlur() { return this.q.shadowBlur; } set shadowBlur(v) { this.q.shadowBlur = v; }
  get shadowColor() { return this.q.shadowColor; } set shadowColor(v) { this.q.shadowColor = v; }
  get shadowOffsetX() { return this.q.shadowOffsetX; } set shadowOffsetX(v) { this.q.shadowOffsetX = v; }
  get shadowOffsetY() { return this.q.shadowOffsetY; } set shadowOffsetY(v) { this.q.shadowOffsetY = v; }
  get lineDashOffset() { return this._dashOffset; } set lineDashOffset(v) { this._dashOffset = v; this.q.lineDashOffset = v; }
  setLineDash(a) { this._dash = a; this.q.setLineDash(a); }
  getLineDash() { return this._dash; }
  get filter() { return this._filter || "none"; } set filter(v) { this._filter = v; } // not available in Qt
  get direction() { return "ltr"; } set direction(v) {}
  // paths
  beginPath() { this.q.beginPath(); }
  closePath() { this.q.closePath(); }
  moveTo(x, y) { this.q.moveTo(x, y); }
  lineTo(x, y) { this.q.lineTo(x, y); }
  quadraticCurveTo(a, b, c, d) { this.q.quadraticCurveTo(a, b, c, d); }
  bezierCurveTo(a, b, c, d, e, f) { this.q.bezierCurveTo(a, b, c, d, e, f); }
  arc(x, y, r, s, e, ccw) { this.q.arc(x, y, Math.max(0, r), s, e, !!ccw); }
  arcTo(a, b, c, d, r) { this.q.arcTo(a, b, c, d, Math.max(0, r)); }
  rect(x, y, w, h) { this.q.rect(x, y, w, h); }
  ellipse(x, y, rx, ry, rot, s, e, ccw) {
    // HTML ellipse = an arc on a transformed unit circle. Qt's path
    // transform-at-construction lets us do it with save/scale/restore.
    rx = Math.max(0, rx); ry = Math.max(0, ry);
    if (rx === 0 || ry === 0) return;
    this.q.save();
    this.q.translate(x, y); this.q.rotate(rot || 0); this.q.scale(rx, ry);
    this.q.arc(0, 0, 1, s, e, !!ccw);
    this.q.restore();
  }
  roundRect(x, y, w, h, r) {
    let rr = Array.isArray(r) ? r[0] : (r || 0);
    rr = Math.max(0, Math.min(rr, Math.abs(w) / 2, Math.abs(h) / 2));
    this.q.moveTo(x + rr, y);
    this.q.arcTo(x + w, y, x + w, y + h, rr);
    this.q.arcTo(x + w, y + h, x, y + h, rr);
    this.q.arcTo(x, y + h, x, y, rr);
    this.q.arcTo(x, y, x + w, y, rr);
    this.q.closePath();
  }
  _replay(p) {
    this.q.beginPath();
    for (const [op, a] of p.ops) this[op](...a);
  }
  fill(p, rule) {
    if (p instanceof Path2D) { this._replay(p); }
    else if (typeof p === "string") rule = p;
    this.q.fillRule = rule === "evenodd" ? Qt.OddEvenFill : Qt.WindingFill;
    this.q.fill();
  }
  stroke(p) { if (p instanceof Path2D) this._replay(p); this.q.stroke(); }
  clip(p, rule) {
    if (p instanceof Path2D) this._replay(p);
    else if (typeof p === "string") rule = p;
    this.q.fillRule = rule === "evenodd" ? Qt.OddEvenFill : Qt.WindingFill;
    // Qt maps the clip already in place by the CURRENT transform when it
    // intersects a new one (a clip under translate(0, 70) moved the one before
    // 70 px down). The path is mapped as it is built, so clip with no
    // transform and put it back: the clips stay where they were made.
    const m = this.m;
    this.q.setTransform(1, 0, 0, 1, 0, 0);
    this.q.clip();
    this.q.setTransform(m.a, m.b, m.c, m.d, m.e, m.f);
  }
  isPointInPath(...a) { return this.q.isPointInPath(...a.slice(-2)); }
  // rects, text, gradients, images
  fillRect(x, y, w, h) { this.q.fillRect(x, y, w, h); }
  strokeRect(x, y, w, h) { this.q.strokeRect(x, y, w, h); }
  clearRect(x, y, w, h) { this.q.clearRect(x, y, w, h); }
  fillText(t, x, y) { this.q.fillText(t, x, y); }
  strokeText(t, x, y) { this.q.strokeText(t, x, y); }
  measureText(t) { return this.q.measureText(t); }
  createLinearGradient(a, b, c, d) { return this.q.createLinearGradient(a, b, c, d); }
  createRadialGradient(a, b, c, d, e, f) { return this.q.createRadialGradient(a, b, c, d, e, f); }
  drawImage(...a) {
    if (a[0] && a[0].__qmlImage) a[0] = a[0].__qmlImage;
    // Port (robot-heads): pixels (ImageData, the off-screen canvases') go as a
    // pattern fill: Qt's drawImage rounds the destination to whole pixels
    // before the transform, so a head drawn in head units (a screen 0.6 × 0.4
    // across, scaled up) came out as nothing.
    const img = a[0];
    if (img && img.data && img.width !== undefined && a.length >= 3) { this._drawData(img, a); return; }
    this.q.drawImage(...a);
  }
  _drawData(img, a) {
    let sx = 0, sy = 0, sw = img.width, sh = img.height, dx, dy, dw, dh;
    if (a.length === 3) { dx = a[1]; dy = a[2]; dw = sw; dh = sh; }
    else if (a.length === 5) { dx = a[1]; dy = a[2]; dw = a[3]; dh = a[4]; }
    else { sx = a[1]; sy = a[2]; sw = a[3]; sh = a[4]; dx = a[5]; dy = a[6]; dw = a[7]; dh = a[8]; }
    if (!sw || !sh || !dw || !dh) return;
    const q = this.q;
    const pat = q.createPattern(img, "no-repeat");
    q.save();
    q.translate(dx, dy);
    q.scale(dw / sw, dh / sh);
    q.translate(-sx, -sy);
    q.fillStyle = pat;
    q.fillRect(sx, sy, sw, sh);
    q.restore();
  }
  // Port (robot-heads): pixels, patterns and smoothing.
  createImageData(w, h) { return this.q.createImageData(w, h); }
  getImageData(x, y, w, h) { return this.q.getImageData(x, y, w, h); }
  // Qt draws putImageData only in its 7-argument form (the dirty rect given):
  // the short one is silently ignored.
  // It also blends where HTML replaces (transparent pixels left what was
  // there: a canvas put to every frame piled the frames up): the area is
  // cleared first, untransformed, as putImageData ignores the transform.
  putImageData(img, x, y, dx, dy, dw, dh) {
    if (dw === undefined) { dx = 0; dy = 0; dw = img.width; dh = img.height; }
    const q = this.q;
    q.save();
    q.setTransform(1, 0, 0, 1, 0, 0);
    q.clearRect(x + dx, y + dy, dw, dh);
    q.restore();
    q.putImageData(img, x, y, dx, dy, dw, dh);
  }
  createPattern(img, rep) { if (img && img.__qmlImage) img = img.__qmlImage; return this.q.createPattern(img, rep); }

}
