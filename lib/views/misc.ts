// The DOM-free parts of the in-island settings, the wardrobe, the weekly recap
// card and the file drop, for SettingsView / WardrobeView / RecapView /
// UploadLayer.qml. Upstream's drawing code is imported and run as is; only
// what a view builder decides inline is mirrored here, citing where.

import * as Looks from "../looks";
import { State } from "@coucou/core/state";
import { UploadCanvas } from "@coucou/upload/canvas";
import { UploadSeq, type UploadFrame } from "@coucou/upload/sequence";
import { renderShareImage } from "@coucou/recap/share";
import { Recap } from "@coucou/recap/recap";
import { formatCount, formatDuration, weekRangeLabel, type WeeklySummary } from "@coucou/recap/summary";
import { drawWardrobeIcon } from "@coucou/mascot/outfits";
import {
  OUTFIT_KEYS, WARDROBE_STRINGS, parseOutfit, resolveOutfit, seasonalOutfit, wardrobeHeader,
  type OutfitSelection,
} from "@coucou/mascot/wardrobe";
import { language, t } from "@coucou/i18n/i18n";
import { CtxWrap } from "../shims.js";
import { island as islandNow } from "../main";
import { tintUpload } from "../personal-only";

declare const Qt: any;

// ── Canvas text the CSS way ──────────────────────────────────────────────────

/** What every Coucou canvas stack resolves to here (style.css --font = system-ui). */
const FAMILY = '"Adwaita Sans"';
const MONO_FAMILY = "monospace";

/**
 * CtxWrap for canvases that draw text. Qt's Context2D truncates a fractional
 * pixel size (12.5px → 12px) and resolves `system-ui` to another family, and
 * reads `font` back in its own format. This keeps the CSS string, sets an
 * integer font Qt can hold, and scales fillText / measureText to the exact size.
 */
export class TextCtx extends CtxWrap {
  private _css = "10px sans-serif";
  private _k = 1;
  // CtxWrap's `filter` (ignored by Qt) stores into `_filter`; created here up
  // front, because V4 threw a bare TypeError adding it mid-frame (drawProgressBar).
  private _filter = "none";
  private _px = 10;
  private _weight = 400;
  private _family = "Adwaita Sans";
  private _fontKey = "";
  /** A QML FontMetrics, for the baseline offsets fillText needs (see below). */
  private _metrics: { font: unknown; ascent: number; descent: number } | null = null;

  constructor(ctx: unknown, canvas: unknown) {
    super(ctx, canvas);
    try {
      this._metrics = Qt.createQmlObject("import QtQuick; FontMetrics {}", canvas as never) as never;
    } catch {
      this._metrics = null;
    }
  }

  get font(): string { return this._css; }
  set font(v: string) {
    const m = /^\s*(?:(normal|bold|\d{3})\s+)?(\d+(?:\.\d+)?)px\s+(.*)$/.exec(String(v));
    if (!m) { this.q.font = v; this._css = v; this._k = 1; return; }
    const weight = m[1] === "bold" ? 700 : Number(m[1] || 400);
    const size = Number(m[2]);
    const mono = /mono|consolas/i.test(m[3]);
    // Integer px at 4× when fractional; the text is scaled back on draw.
    const px = Number.isInteger(size) ? size : Math.round(size * 4);
    this._k = size / px;
    this._px = px;
    this._weight = weight;
    this._family = mono ? "monospace" : "Adwaita Sans";
    this.q.font = `${weight} ${px}px ${mono ? MONO_FAMILY : FAMILY}`;
    this._css = v;
  }

  /**
   * Qt's fillText fills the glyph outlines even-odd, so a variable font's
   * overlapping contours (Adwaita Sans "4", "D"…) show holes. The text goes
   * through the path instead (`text()` + a nonzero fill), placed by hand:
   * `text()` ignores textAlign / textBaseline. Baselines follow the em box,
   * as Chromium does. Like fillText it leaves no path behind (it does reset
   * the current one, which upstream never relies on across a fillText).
   */
  fillText(s: string, x: number, y: number) {
    const q = this.q;
    const fm = this._metrics;
    if (!fm) { this.plainFillText(s, x, y); return; }
    const key = `${this._family}|${this._px}|${this._weight}`;
    if (key !== this._fontKey) {
      this._fontKey = key;
      fm.font = Qt.font({ family: this._family, pixelSize: this._px, weight: this._weight });
    }
    const w = q.measureText(s).width;
    const align = q.textAlign;
    const dx = align === "center" ? -w / 2 : align === "right" || align === "end" ? -w : 0;
    const base = q.textBaseline;
    const dy = base === "middle" ? (fm.ascent - fm.descent) / 2
      : base === "top" ? fm.ascent
      : base === "hanging" ? fm.ascent * 0.8
      : base === "bottom" ? -fm.descent
      : 0;
    q.save();
    q.translate(x, y);
    if (this._k !== 1) q.scale(this._k, this._k);
    q.beginPath();
    q.text(s, dx, dy);
    q.fillRule = Qt.WindingFill;
    q.fill();
    q.beginPath();
    q.restore();
  }
  private plainFillText(s: string, x: number, y: number) {
    if (this._k === 1) { this.q.fillText(s, x, y); return; }
    this.q.save();
    this.q.translate(x, y);
    this.q.scale(this._k, this._k);
    this.q.fillText(s, 0, 0);
    this.q.restore();
  }
  measureText(s: string) {
    const w = this.q.measureText(s).width * this._k;
    return { width: w };
  }
}

// ── Settings (views/views.ts buildSettings) ─────────────────────────────────

/** The segmented control's values, as buildSettings lists them. */
export const AUTO_CLOSE_STEPS = [10, 15, 30];

// ── Wardrobe (views/wardrobe.ts) ─────────────────────────────────────────────

/** Icon side, as wardrobe.ts ICON. */
export const WARDROBE_ICON = 28;

/** drawIcons(): one button's icon, with "auto" in the season's outfit and badge. */
export function drawWardrobeButton(ctx: CanvasRenderingContext2D, sel: OutfitSelection) {
  drawWardrobeIcon(ctx, WARDROBE_ICON, sel, seasonalOutfit(new Date()), WARDROBE_STRINGS.autoBadge);
}

/** What makes "auto"'s icon change: the season and the language of its badge. */
export function wardrobeIconKey(): string {
  return `${seasonalOutfit(new Date())}|${language()}`;
}

/** The button's title (tooltip). */
export function wardrobeTitle(sel: OutfitSelection): string {
  return t(OUTFIT_KEYS[sel]);
}

/** Port (his ask): the outfit of the chat in front (lib/looks.ts), else Settings'. */
function wornOutfit(): string {
  const conv = Looks.frontConv();
  return conv ? Looks.outfitOf(conv) : State.settings.mascotOutfit;
}

/** updateNote(): the grey text at the right of the header. */
export function wardrobeNote(hovered: OutfitSelection | null): string {
  return wardrobeHeader(hovered, parseOutfit(wornOutfit()), new Date());
}

/** sync(): the outfit whose button has `.on`. */
export function wardrobeCurrent(): OutfitSelection {
  return parseOutfit(wornOutfit());
}

/** mouseenter: what previewOutfit gets. */
export function wardrobePreviewFor(sel: OutfitSelection) {
  return resolveOutfit(sel, new Date());
}

// ── Weekly recap (views/recap.ts) ────────────────────────────────────────────

// recap/summary.ts formatCount() groups with toLocaleString("en-US"); V4's
// Number#toLocaleString ignores the locale and does not group ("1217").
if ((1234).toLocaleString("en-US") !== "1,234") {
  const orig = Number.prototype.toLocaleString;
  Number.prototype.toLocaleString = function (this: number, loc?: string | string[], opts?: object) {
    if (loc !== "en-US" || opts !== undefined || !Number.isInteger(+this)) return orig.call(this, loc as never, opts as never);
    return String(+this).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  } as typeof Number.prototype.toLocaleString;
}

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

export interface RecapModel {
  empty: boolean;
  version: number;
  title: string;
  range: string;
  chips: { v: string; l: string }[];
  /** metaLine() rows: [label, value] pairs, empty rows left out. */
  meta: [string, string][][];
}

/** summaryBody() / emptyBody(): what the card shows for Recap.summary. */
export function recapModel(): RecapModel {
  const s = Recap.summary;
  const base = { version: Recap.version, title: t("Weekly recap") };
  if (!s) return { ...base, empty: true, range: "", chips: [], meta: [] };
  const chips = [
    { v: formatDuration(s.totalMinutes), l: t("coding") },
    { v: formatCount(s.sessionCount), l: plural(s.sessionCount, t("session"), t("sessions")) },
    { v: formatCount(s.filesChanged), l: plural(s.filesChanged, t("file"), t("files")) },
  ];
  if (s.linesAdded + s.linesRemoved > 0) {
    chips.push({ v: `+${formatCount(s.linesAdded)} / −${formatCount(s.linesRemoved)}`, l: t("lines") });
  }
  if (s.commandsRun > 0) chips.push({ v: formatCount(s.commandsRun), l: t("commands") });

  const first: [string, string][] = [];
  if (s.topAgent) first.push([t("Top agent"), s.topAgent]);
  if (s.topProject) first.push([t("Top project"), s.topProject]);
  if (s.busiestDay) first.push([t("Busiest day"), t(s.busiestDay)]);
  const second: [string, string][] = [];
  if (s.longestSessionMinutes > 1) second.push([t("Longest session"), formatDuration(s.longestSessionMinutes)]);
  if (s.permissionsAllowed + s.permissionsDenied > 0) {
    second.push([t("Permissions"), t("{allowed} allowed, {denied} denied", {
      allowed: s.permissionsAllowed, denied: s.permissionsDenied,
    })]);
  }
  if (s.questions > 0) second.push([t("Questions"), formatCount(s.questions)]);

  return { ...base, empty: false, range: weekRangeLabel(s), chips, meta: [first, second].filter((m) => m.length > 0) };
}

/** dayKey(s.weekStart) for recapSavePng. */
export { dayKey } from "@coucou/recap/summary";

/**
 * renderShareImage() into a QML Canvas (1080 × 1920): its
 * `document.createElement("canvas")` gets the QML context for the call.
 */
export function drawShareImage(qmlCtx: unknown, qmlCanvas: unknown, hideProjects: boolean): boolean {
  const s: WeeklySummary | null = Recap.summary;
  if (!s) return false;
  const doc = document as unknown as { createElement: (tag: string) => unknown };
  const orig = doc.createElement;
  const wrap = new TextCtx(qmlCtx, qmlCanvas);
  doc.createElement = () => ({ width: 0, height: 0, style: {}, getContext: () => wrap });
  try {
    renderShareImage(s, hideProjects);
  } finally {
    doc.createElement = orig;
  }
  return true;
}

// ── File drop (upload/canvas.ts, driven by upload/sequence.ts) ───────────────

/** UploadCanvas without its DOM: only its drawing methods are used. */
const painter = Object.create(UploadCanvas.prototype) as {
  drawScene(ctx: CanvasRenderingContext2D, f: UploadFrame, wallTime: number): void;
};

/** The two painted choose buttons (canvas.ts ASK_BTN / CANCEL_BTN), as hit areas. */
export const UPLOAD_HITS = { ask: { x: 114, w: 168 }, cancel: { x: 290, w: 120 }, y: 113, h: 26 };

/**
 * UploadCanvas.draw(): one frame of the drop sequence into `ctx` (640 × 176,
 * already cleared by the caller). Returns whether the choose buttons are live.
 */
export function drawUpload(ctx: CanvasRenderingContext2D, wallTime: number): boolean {
  const f = UploadSeq.frame();
  painter.drawScene(tintUpload(ctx, islandNow?.engine.bodyColor ?? null), f, wallTime);
  return f.chooseAlpha > 0.5;
}

/** views/upload.ts buildUploading() sync(): the fallback progress card's text. */
export function uploadingLabel(): { name: string; pct: string; done: boolean } {
  const done = State.uploadProgress >= 0.999;
  const pct = Math.round(State.uploadProgress * 100);
  return {
    done,
    name: done
      ? `✓  ${State.droppedFile?.name ?? t("File")}`
      : t("Uploading {name}", { name: State.droppedFile?.name ?? t("file") }),
    pct: done ? "" : `${pct} %`,
  };
}
