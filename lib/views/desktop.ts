// The mascot on the desktop, the shell side: what upstream splits between the
// desktop window's page (windows/src/desktop/main.ts, class DesktopMascot) and
// the Rust window owner (windows/src-tauri/src/desktop.rs, layer-shell mode).
// DOM-free ports of both, for desktop/RoboDesktop.qml (the layer surface)
// and desktop/DesktopMascotItem.qml (his canvas and the mouse).
//
// The island side is upstream's own DesktopLink (island/desktop.ts), in the
// bundle untouched: its Bridge.desktop* calls reach `DesktopWindow.command`
// through Robo.qml's desktopHandler, its emitToWindow("mascot", …) reaches
// `DesktopPage.onEvent` through Robo.windowCommand("emit:mascot:<name>").
//
// Additions asked for by the port: Hyprland gives the global cursor, so his
// eyes follow it everywhere and the sleep rule measures the real distance
// (upstream's Windows "poll" behaviour), polled only while he is awake on the
// desktop; drags and carries follow it too, so he can live on any display
// (see "The window"). Everything else is the Linux layer-shell path.

import { BotEngine } from "@coucou/mascot/engine";
import { State } from "@coucou/core/state";
import { Robot } from "../robot/mascot";
import { RobotSim } from "../robot/tv/sim";
import * as Robo from "../robot/config";
import { island as islandNow } from "../main";
import { Sound } from "@coucou/core/sound";
import type { BotEmoteName } from "@coucou/core/layout";
import {
  DESKTOP_EVENTS, DOUBLE_CLICK_MS, DRAG_THRESHOLD, PANEL_SIZE, agentActive, gaze, isOverBody,
  lookOrigin, pointerDistance, shouldSleep,
  type DesktopSnapshot, type Point,
} from "@coucou/mascot/desktop-logic";
import { LEGACY_PLACE_KEY } from "../personal-only";

// ── desktop.rs `logic` ───────────────────────────────────────────────────────

/** desktop.rs SIZE / MARGIN / FLIGHT_MS / SNAP_MS / TICK_MS. */
export const SIZE = 120;
export const MARGIN = 24;
export const FLIGHT_MS = 450;
export const SNAP_MS = 250;
export const TICK_MS = 16;
/** island.rs PANEL_W / PANEL_H: dropping him on the panel brings him home. */
export const HOME_ZONE_W = 720;
export const HOME_ZONE_H = 320;

export interface Rect { x: number; y: number; w: number; h: number }
export interface Display { frame: Rect; work: Rect; scale: number }

const contains = (r: Rect, p: Point) => p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;
const center = (r: Rect): Point => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });
const dist2 = (a: Point, b: Point) => (a.x - b.x) ** 2 + (a.y - b.y) ** 2;

export function clampOrigin(o: Point, size: number, work: Rect, margin: number): Point {
  return {
    x: Math.min(Math.max(o.x, work.x + margin), work.x + work.w - size - margin),
    y: Math.min(Math.max(o.y, work.y + margin), work.y + work.h - size - margin),
  };
}

export function displayNear(p: Point, displays: Display[]): Display | null {
  const hit = displays.find((d) => contains(d.frame, p));
  if (hit) return hit;
  let best: Display | null = null;
  for (const d of displays) if (!best || dist2(p, center(d.work)) < dist2(p, center(best.work))) best = d;
  return best;
}

export function settle(o: Point, displays: Display[], size: number, margin: number): Point {
  const first = displays[0];
  if (!first) return o;
  const half = (size * first.scale) / 2;
  const d = displayNear({ x: o.x + half, y: o.y + half }, displays);
  if (!d) return o;
  return clampOrigin(o, size * d.scale, d.work, margin * d.scale);
}

export function restoreSpot(spot: Point, displays: Display[], size: number, margin: number): Point | null {
  for (const d of displays) {
    const s = size * d.scale;
    if (contains(d.frame, { x: spot.x + s / 2, y: spot.y + s / 2 })) return clampOrigin(spot, s, d.work, margin * d.scale);
  }
  return null;
}

export function defaultSpot(d: Display, size: number, margin: number): Point {
  const s = size * d.scale, m = margin * d.scale;
  return { x: d.work.x + d.work.w - s - m, y: d.work.y + d.work.h - s - m };
}

export function homeZone(cx: number, top: number, scale: number): Rect {
  return { x: cx - (HOME_ZONE_W * scale) / 2, y: top, w: HOME_ZONE_W * scale, h: HOME_ZONE_H * scale };
}

export function islandSpot(cx: number, top: number, size: number, scale: number): Point {
  return { x: cx - (size * scale) / 2, y: top };
}

export function easeInOut(t: number): number {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

export function easeOutBack(t: number): number {
  const c1 = 1.3, c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
}

const lerp = (a: Point, b: Point, t: number): Point => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });

// ── The window (desktop.rs, DesktopMode::Layer, on every display) ────────────
//
// Upstream's layer mode keeps him on the island's display. The port lets him
// live on any display: positions are global (Hyprland layout px = Quickshell
// screen x/y) and the shell draws him through, per display,
//   * his small window (120 px, upstream's): where he sits and takes the
//     mouse. Top layer while he sits (a fullscreen app covers him, as
//     upstream), overlay layer while he moves (above the notch);
//   * a full-display window on the overlay layer, up on every display while
//     he may cross displays ("spread": a drag, a carry out of the island, a
//     flight between displays), drawing him wherever he is.
// During drags and carries the global cursor (Hyprland) moves him, so he
// follows the pointer onto any display whichever surface holds the grab.

/** A display, global logical px. */
export interface Screen { name: string; frame: Rect }

/** What the window needs from the shell. */
export interface WindowHost {
  /** ambxst-robo request (desktop_mascot_info / desktop_mascot_remember). */
  core(cmd: string, args: Record<string, unknown>): Promise<any>;
  /** Event to the island page (`app.emit_to(island, …)`). */
  emitIsland(name: string, payload?: unknown): void;
  /** Every display. */
  screens(): Screen[];
  /** The display the island (the notch Robo opens in) is on; one of screens(). */
  islandScreen(): Screen | null;
  /** The island's top-centre on its display, display-local (island_anchor; upstream (w/2, 0)). */
  islandAnchor(display: { w: number; h: number }): { cx: number; top: number };
  /** Island-window client coordinates → display-local logical px (from_island_client). */
  fromIslandClient(x: number, y: number, display: { w: number; h: number }): Point | null;
  /**
   * Start / stop following the global cursor: while on, the shell calls
   * followTo(global) at ~60 Hz. False when there is no global cursor.
   */
  follow(on: boolean): boolean;
  /** One fresh read of the global cursor (null when unknown). */
  cursorNow(): Promise<Point | null>;
  /** Geometry, input shape, visibility or the cursor gate changed: re-read them. */
  changed(): void;
  /**
   * The notch's rectangle on a display, display-local (as it is now: closed
   * or open); null when unknown (then upstream's 720×320 panel zone is used).
   */
  notchRect?(screen: string): Rect | null;
  /** A drag of him came near the island's notch (true) or left it / ended (false). */
  nearNotch?(near: boolean): void;
  /**
   * Where the island's own mascot is drawn right now (the open notch's, else
   * the bar's on the island's display): his body's centre, global, and its
   * body box (engine width). Flights home end there, flights out start there.
   */
  homeTarget?(): { x: number; y: number; size: number } | null;
  /** Small persistent strings (default: localStorage). */
  store?: { get(key: string): string | null; set(key: string, value: string): void };
}

export type MouseShape = "empty" | "whole" | "disc";

/** What one display's windows show (DesktopWindow.view). */
export interface ScreenView {
  /** His small window is on this display. */
  small: boolean;
  /** It draws him (while spread the full windows do). */
  smallDraws: boolean;
  smallLayer: "top" | "overlay";
  /** Its top-left, display-local (layer margins). */
  smallX: number;
  smallY: number;
  smallShape: MouseShape;
  /** The full-display window is up. */
  full: boolean;
  /** Its input: the whole display during a drag of him (the drop is caught wherever it lands). */
  fullShape: "whole" | "empty";
  /** His top-left, display-local. */
  x: number;
  y: number;
  /** His drawing's scale about his box's centre (flights to / from the island's mascot). */
  scale: number;
}

/** A carry or drag whose cursor has not moved for this long is dropped (a lost release). */
export const STALL_MS = 10000;

let quietUntil = 0;
/**
 * The next fly-out (within a few seconds) is a shell reload's restore, not a
 * launch: he simply appears at his spot. main.ts calls it when it skips the greeting.
 */
export function quietLaunch(ms = 4000) {
  quietUntil = Date.now() + ms;
}

/** Dropping him on the notch, or this close to it, sends him home. */
export const NOTCH_DROP_MARGIN = 24;
/** A drag this close to the notch opens it (so he can be dropped in). */
export const NOTCH_NEAR = 160;

export function inflate(r: Rect, m: number): Rect {
  return { x: r.x - m, y: r.y - m, w: r.w + 2 * m, h: r.h + 2 * m };
}

/** Where the saved spot's display is (localStorage): the core keeps x/y display-local. */
export const PLACE_KEY = "coucou.desktopMascot.display";
export interface PlaceTag { name: string; x: number; y: number; w: number; h: number; spot: Point }

/** The display a saved spot was measured on, matched like island.rs matches the island's. */
export function matchScreen(tag: PlaceTag, all: Screen[]): Screen | null {
  const at = (s: Screen) => s.frame.x === tag.x && s.frame.y === tag.y;
  const dims = (s: Screen) => s.frame.w === tag.w && s.frame.h === tag.h;
  let hit = all.find((s) => at(s) && s.name === tag.name) || all.find((s) => s.name === tag.name && dims(s));
  if (!hit) {
    const named = all.filter((s) => s.name === tag.name);
    if (named.length === 1) hit = named[0];
  }
  if (!hit) hit = all.find((s) => at(s) && dims(s));
  return hit ?? null;
}

const centreOf = (p: Point): Point => ({ x: p.x + SIZE / 2, y: p.y + SIZE / 2 });
const asDisplay = (s: Screen): Display => ({ frame: s.frame, work: s.frame, scale: 1 });

type Source = "island" | "desktop";

export class DesktopWindow {
  readonly mode = "layer" as const;
  shown = false;
  landed = false;
  asleep = false;
  carry: { from: Source } | null = null;
  /** A drag of him from the desktop (his small window holds the pointer grab). */
  dragging = false;
  /** A flight (fly out / home / snap) is under way. */
  flying = false;
  /** The full-display windows draw him (he may cross displays). */
  spread = false;
  /** The shell feeds followTo() with the global cursor. */
  following = false;
  /** Top-left corner, global logical px. */
  pos: Point = { x: 0, y: 0 };
  /** The display under his centre. */
  screen: string | null = null;
  /** His small window: its display and top-left (frozen while spread). */
  smallScreen: string | null = null;
  smallPos: Point = { x: 0, y: 0 };
  /** The island's display at pick-up / fly-out (layer_display). */
  islandAt: Screen | null = null;
  /** The drag is near the notch (host.nearNotch). */
  near = false;
  /** His drawing's scale (1 on the desktop; the island the mascot's size at the notch). */
  scale = 1;
  /** Settings → "Keep the mascot above fullscreen apps": overlay layer even when he sits. */
  keepAbove = false;
  /**
   * The carry's pointer grab (held by the notch) may be gone: the cursor left
   * the notch's display, or the notch closed. The full windows then take
   * the mouse, so the next release / click anywhere drops him.
   */
  carryLoose = false;
  private lastMoveAt = 0;
  private drag: { grab: Point; anchor: Point } | null = null;
  private flight = 0;
  private host: WindowHost;
  page: DesktopPage | null = null;

  constructor(host: WindowHost) {
    this.host = host;
  }

  /** Compatibility (debug): the full windows are up. */
  get overlay(): boolean {
    return this.spread;
  }

  /** What his small window takes from the mouse (refresh()). Asleep: all of it, as with a cursor poll. */
  get shape(): MouseShape {
    if (!this.shown) return "empty";
    if (this.dragging) return "disc";
    if (!this.landed || this.carry || this.spread) return "empty";
    return this.asleep ? "whole" : "disc";
  }

  /** The cursor poll's gate: awake and sitting on the desktop. */
  get cursorActive(): boolean {
    return this.shown && this.landed && !this.asleep && !this.carry && !this.dragging && !this.spread && !this.flying;
  }

  /** Port (his ask): the cursor feeds his eyes: as cursorActive, and Robo's in flight too (he keeps looking at it on his way home or out). */
  get eyesActive(): boolean {
    return this.cursorActive || (this.shown && this.flying && Robo.isRobo());
  }

  /** One display's windows (by name). */
  view(name: string): ScreenView {
    const s = this.all().find((x) => x.name === name);
    const fx = s ? s.frame.x : 0, fy = s ? s.frame.y : 0;
    const small = this.shown && this.smallScreen === name;
    const moving = !this.landed || this.flying || this.dragging || !!this.carry || this.keepAbove;
    return {
      small,
      smallDraws: small && !this.spread,
      smallLayer: moving ? "overlay" : "top",
      smallX: Math.round(this.smallPos.x - fx),
      smallY: Math.round(this.smallPos.y - fy),
      smallShape: small ? this.shape : "empty",
      full: this.shown && this.spread,
      fullShape: this.dragging || (!!this.carry && this.carryLoose) ? "whole" : "empty",
      x: this.pos.x - fx,
      y: this.pos.y - fy,
      scale: this.scale,
    };
  }

  private emitPage(name: string, payload?: unknown) {
    this.page?.onEvent(name, payload);
  }

  private all(): Screen[] {
    return this.host.screens() || [];
  }

  private displays(): Display[] {
    return this.all().map(asDisplay);
  }

  /** The display under (or nearest to) a point. */
  private screenAt(p: Point): Screen | null {
    const all = this.all();
    const d = displayNear(p, all.map(asDisplay));
    return d ? all.find((s) => s.frame === d.frame) ?? null : null;
  }

  private island(): Screen | null {
    return this.host.islandScreen();
  }

  /** The island's top-centre, global. */
  private anchorOf(s: Screen): { cx: number; top: number } {
    const a = this.host.islandAnchor({ w: s.frame.w, h: s.frame.h });
    return { cx: s.frame.x + a.cx, top: s.frame.y + a.top };
  }

  private fromIsland(x: number, y: number, s: Screen | null): Point | null {
    if (!s) return null;
    const c = this.host.fromIslandClient(x, y, { w: s.frame.w, h: s.frame.h });
    return c ? { x: s.frame.x + c.x - SIZE / 2, y: s.frame.y + c.y - SIZE / 2 } : null;
  }

  private place(p: Point) {
    this.pos = p;
    const s = this.screenAt(centreOf(p));
    this.screen = s ? s.name : null;
    if (!this.spread) {
      this.smallPos = p;
      if (this.shown || this.smallScreen) this.smallScreen = this.screen;
    }
    this.host.changed();
  }

  /** He sits where he is: back in his small window, on the display under him. */
  private land() {
    this.flying = false;
    this.spread = false;
    this.smallPos = this.pos;
    this.smallScreen = this.screen;
    this.refresh();
  }

  private show(at: Point) {
    this.shown = true;
    this.place(at);
    this.refresh();
    this.emitPage("desktop-visible", true);
  }

  private hide() {
    this.stopFollow();
    this.setNear(false);
    this.shown = false;
    this.landed = false;
    this.carry = null;
    this.asleep = false;
    this.dragging = false;
    this.drag = null;
    this.flying = false;
    this.spread = false;
    this.carryLoose = false;
    this.scale = 1;
    this.smallScreen = null;
    this.refresh();
    this.emitPage("desktop-visible", false);
  }

  private refresh() {
    this.host.changed();
  }

  private stopFollow() {
    if (this.following) this.host.follow(false);
    this.following = false;
  }

  private fly(to: Point | (() => Point), ms: number, ease: (t: number) => number, scaleTo?: number | (() => number)): Promise<boolean> {
    const token = ++this.flight;
    const from = this.pos;
    const fromScale = this.scale;
    const target = typeof to === "function" ? to : () => to;
    const targetScale = scaleTo === undefined ? () => fromScale : typeof scaleTo === "function" ? scaleTo : () => scaleTo;
    const steps = Math.max(1, Math.floor(ms / TICK_MS));
    this.flying = true;
    this.refresh();
    return new Promise((resolve) => {
      let k = 0;
      const id = setInterval(() => {
        if (this.flight !== token) {
          clearInterval(id);
          resolve(false);
          return;
        }
        k++;
        if (k > steps) {
          clearInterval(id);
          this.flying = false;
          resolve(true);
          return;
        }
        const e = ease(k / steps);
        this.scale = fromScale + (targetScale() - fromScale) * e;
        this.place(lerp(from, target(), e));
      }, TICK_MS);
    });
  }

  private remember(args: { onDesktop?: boolean; spot?: Point | null }) {
    this.host.core("desktop_mascot_remember", args).catch(() => {});
  }

  private store(): { get(k: string): string | null; set(k: string, v: string): void } | null {
    if (this.host.store) return this.host.store;
    try {
      if (typeof localStorage !== "undefined")
        return { get: (k) => localStorage.getItem(k), set: (k, v) => localStorage.setItem(k, v) };
    } catch {
      /* no storage */
    }
    return null;
  }

  /** Saves his spot: x/y measured from his display's corner (the core), the display by name (here). */
  private rememberSpot(spot: Point) {
    const s = this.screenAt(centreOf(spot));
    const local = s ? { x: spot.x - s.frame.x, y: spot.y - s.frame.y } : spot;
    if (s) {
      const tag: PlaceTag = { name: s.name, x: s.frame.x, y: s.frame.y, w: s.frame.w, h: s.frame.h, spot: local };
      try {
        this.store()?.set(PLACE_KEY, JSON.stringify(tag));
      } catch {
        /* the core still has x/y */
      }
    }
    this.remember({ onDesktop: true, spot: local });
  }

  /** A saved display-local spot → global. Untagged (saved before): the island's display, as upstream. */
  private globalSpot(saved: Point, island: Screen | null): Point | null {
    let tag: PlaceTag | null = null;
    try {
      const st = this.store();
      // (A tag saved under the key the personal build used before: personal-only.ts.)
      const raw = st ? st.get(PLACE_KEY) ?? (LEGACY_PLACE_KEY ? st.get(LEGACY_PLACE_KEY) : null) : null;
      tag = raw ? JSON.parse(raw) : null;
    } catch {
      tag = null;
    }
    if (tag && tag.spot && Math.abs(tag.spot.x - saved.x) < 0.5 && Math.abs(tag.spot.y - saved.y) < 0.5) {
      const s = matchScreen(tag, this.all());
      return s ? { x: s.frame.x + saved.x, y: s.frame.y + saved.y } : null;
    }
    return island ? { x: island.frame.x + saved.x, y: island.frame.y + saved.y } : null;
  }

  private async targetSpot(anywhere: boolean, island: Screen): Promise<Point | null> {
    let saved: { x: number; y: number; space?: string } | null = null;
    try {
      const info = await this.host.core("desktop_mascot_info", {});
      saved = info && info.spot ? info.spot : null;
    } catch {
      saved = null;
    }
    const corner = () => defaultSpot(asDisplay(island), SIZE, MARGIN);
    if (saved && (saved.space == null || saved.space === "layer")) {
      const g = this.globalSpot(saved, island);
      const restored = g ? restoreSpot(g, this.displays(), SIZE, MARGIN) : null;
      return anywhere ? restored ?? corner() : restored;
    }
    return corner();
  }

  /** The notch on the island's display, global, grown by `margin`; upstream's panel zone when unknown. */
  private notchZone(isl: Screen, margin: number): Rect {
    const r = this.host.notchRect ? this.host.notchRect(isl.name) : null;
    if (r && r.w > 0 && r.h > 0) return inflate({ x: isl.frame.x + r.x, y: isl.frame.y + r.y, w: r.w, h: r.h }, margin);
    const a = this.anchorOf(isl);
    return inflate(homeZone(a.cx, a.top, 1), margin - NOTCH_DROP_MARGIN);
  }

  /** Where he is when in the island: the island the mascot's spot (box top-left + scale), or upstream's anchor. */
  private homeSpot(isl: Screen | null): { pos: Point; scale: number } | null {
    const t = this.host.homeTarget ? this.host.homeTarget() : null;
    if (t && isFinite(t.x) && isFinite(t.y) && t.size > 0)
      return { pos: { x: t.x - SIZE / 2, y: t.y - SIZE / 2 }, scale: t.size / DRAW_W };
    if (!isl) return null;
    const a = this.anchorOf(isl);
    return { pos: islandSpot(a.cx, a.top, SIZE, 1), scale: 1 };
  }

  setKeepAbove(on: boolean) {
    if (this.keepAbove === on) return;
    this.keepAbove = on;
    this.refresh();
  }

  /** The notch may have let go of the carry's pointer grab (it closed). */
  grabLost() {
    if (!this.carry || this.carryLoose) return;
    this.carryLoose = true;
    this.refresh();
  }

  /** A carry or drag whose cursor stood still for STALL_MS: its release was lost. */
  stalled(now: number): boolean {
    return (!!this.carry || this.dragging) && now - this.lastMoveAt > STALL_MS;
  }

  private setNear(near: boolean) {
    if (near === this.near) return;
    this.near = near;
    this.host.nearNotch?.(near);
  }

  /** During a drag: is he near the notch (it opens so he can be dropped in)? */
  private checkNear() {
    const isl = this.island();
    this.setNear(!!isl && this.dragging && contains(this.notchZone(isl, NOTCH_NEAR), centreOf(this.pos)));
  }

  private async finishDrop(pos: Point, from: Source) {
    const c = centreOf(pos);
    const isl = this.island();
    const home = isl ? contains(this.notchZone(isl, NOTCH_DROP_MARGIN), c) : false;
    this.carry = null;
    this.carryLoose = false;
    this.landed = !home;
    if (home) {
      if (from === "island") this.hide();
      else this.refresh();
    } else {
      const spot = settle(pos, this.displays(), SIZE, MARGIN);
      this.refresh();
      const moved = spot.x !== pos.x || spot.y !== pos.y;
      if (!moved || (await this.fly(spot, SNAP_MS, easeOutBack))) this.land();
      this.rememberSpot(spot);
    }
    this.host.emitIsland(DESKTOP_EVENTS.dropped, { from, home });
  }

  // ── Commands (desktop_mascot_*) ──────────────────────────────────────────────

  /** Robo.desktopHandler: the island's Bridge.desktop* calls. */
  command(cmd: string, args: any): unknown {
    args = args || {};
    switch (cmd) {
      case "desktop_mascot_info":
        return this.info();
      case "desktop_mascot_remember":
        return this.host.core(cmd, args).catch(() => null);
      case "desktop_mascot_pick_up":
        return this.pickUp(+args.x, +args.y);
      case "desktop_mascot_carry":
        return this.carryTo(+args.x, +args.y);
      case "desktop_mascot_carry_end":
        return this.carryEnd(+args.x, +args.y);
      case "desktop_mascot_drag_begin":
        return this.dragBegin({ x: SIZE / 2, y: SIZE / 2 }) ? [this.pos.x, this.pos.y] : null;
      case "desktop_mascot_drag_move":
        return null;
      case "desktop_mascot_drag_end":
        return this.dragEnd(null);
      case "desktop_mascot_fly_out":
        return this.flyOut(!!args.anywhere);
      case "desktop_mascot_fly_home":
        return this.flyHome(!!args.forget);
      case "desktop_mascot_set_asleep":
        this.setAsleep(!!args.asleep);
        return null;
    }
    return null;
  }

  async info(): Promise<{ mode: string; onDesktop: boolean }> {
    try {
      const i = await this.host.core("desktop_mascot_info", {});
      return { mode: this.mode, onDesktop: !!(i && i.onDesktop) };
    } catch {
      return { mode: this.mode, onDesktop: false };
    }
  }

  /** The global cursor while following (drag / carry). */
  followTo(g: Point) {
    if (!this.following) return;
    const before = this.pos;
    if (this.dragging && this.drag) {
      this.place({ x: g.x - this.drag.grab.x, y: g.y - this.drag.grab.y });
      this.checkNear();
    } else if (this.carry) {
      this.place({ x: g.x - SIZE / 2, y: g.y - SIZE / 2 });
      const s = this.screenAt(g);
      if (this.islandAt && s && s.name !== this.islandAt.name) this.grabLost();
    }
    if (this.pos.x !== before.x || this.pos.y !== before.y) this.lastMoveAt = Date.now();
  }

  pickUp(x: number, y: number): boolean {
    if (this.shown) return false;
    const isl = this.island();
    const at = this.fromIsland(x, y, isl);
    if (!isl || !at) return false;
    this.flight++;
    this.islandAt = isl;
    this.carry = { from: "island" };
    this.carryLoose = false;
    this.scale = 1;
    this.lastMoveAt = Date.now();
    this.spread = true;
    this.smallScreen = null;
    this.following = this.host.follow(true);
    this.show(at);
    return true;
  }

  /** Island coordinates of the carry: only without a global cursor (it is exact; these are not). */
  carryTo(x: number, y: number) {
    if (!this.carry || this.following) return null;
    const p = this.fromIsland(x, y, this.islandAt);
    if (p) this.place(p);
    return null;
  }

  async carryEnd(x: number, y: number) {
    if (!this.carry) return null;
    const carry = this.carry;
    let pos = this.pos;
    if (this.following) {
      const c = await this.host.cursorNow();
      if (c) pos = { x: c.x - SIZE / 2, y: c.y - SIZE / 2 };
    } else {
      if (isFinite(x) && isFinite(y)) pos = this.fromIsland(x, y, this.islandAt) ?? pos;
    }
    if (this.carry !== carry) return null;
    this.stopFollow();
    this.place(pos);
    await this.finishDrop(pos, "island");
    return null;
  }

  /** The page's drag begins; `grab`: the press, in his own 120 px box. */
  dragBegin(grab: Point): boolean {
    if (!this.landed || this.carry || this.dragging) return false;
    this.flight++;
    this.flying = false;
    this.dragging = true;
    // His small window holds the pointer: its events are relative to it.
    this.drag = { grab, anchor: this.smallPos };
    this.lastMoveAt = Date.now();
    this.spread = true;
    this.following = this.host.follow(true);
    this.refresh();
    return true;
  }

  /** A move seen by his small window (box-local): drives him only without a global cursor. */
  dragMove(local: Point) {
    const d = this.drag;
    if (!this.dragging || !d || this.following) return;
    this.place({ x: d.anchor.x + local.x - d.grab.x, y: d.anchor.y + local.y - d.grab.y });
    this.checkNear();
  }

  /** The button went up (`local`: where, in his small window's box; null: unknown). */
  async dragEnd(local: Point | null) {
    const d = this.drag;
    if (!this.dragging || !d) return null;
    let pos = this.pos;
    if (this.following) {
      const c = await this.host.cursorNow();
      if (c) pos = { x: c.x - d.grab.x, y: c.y - d.grab.y };
    } else if (local) {
      pos = { x: d.anchor.x + local.x - d.grab.x, y: d.anchor.y + local.y - d.grab.y };
    }
    if (this.drag !== d) return null;
    this.stopFollow();
    this.dragging = false;
    this.drag = null;
    this.setNear(false);
    pos = { x: Math.round(pos.x), y: Math.round(pos.y) };
    this.place(pos);
    if (!this.landed) return null;
    await this.finishDrop(pos, "desktop");
    return null;
  }

  async flyOut(anywhere: boolean): Promise<boolean> {
    const isl = this.island();
    if (!isl) return false;
    this.islandAt = isl;
    const quiet = !anywhere && Date.now() < quietUntil;
    quietUntil = 0;
    const target = await this.targetSpot(anywhere, isl);
    if (!target) {
      this.remember({ onDesktop: false });
      return false;
    }
    const start = this.homeSpot(isl);
    if (!start) return false;
    this.stopFollow();
    this.carry = null;
    this.asleep = false;
    this.dragging = false;
    this.drag = null;
    this.setNear(false);
    if (quiet) {
      // A shell reload: he was sitting there all along.
      this.flight++;
      this.landed = true;
      this.spread = false;
      this.scale = 1;
      this.smallScreen = this.screenAt(centreOf(target))?.name ?? null;
      this.show(target);
      this.land();
      return true;
    }
    this.landed = false;
    // From the island's mascot (anywhere on the display, maybe above its top
    // edge): the full windows draw him, his small window takes over at his spot.
    this.spread = true;
    this.smallScreen = null;
    this.scale = start.scale;
    this.show(start.pos);
    this.emitPage("desktop-flight", "out");
    if (!(await this.fly(target, FLIGHT_MS, easeInOut, 1))) return false;
    this.landed = true;
    this.land();
    this.rememberSpot(target);
    return true;
  }

  async flyHome(forget: boolean): Promise<boolean> {
    if (!this.shown) {
      if (forget) this.remember({ onDesktop: false });
      return true;
    }
    this.stopFollow();
    this.landed = false;
    this.carry = null;
    this.asleep = false;
    this.dragging = false;
    this.drag = null;
    this.setNear(false);
    // Home is the island's mascot wherever it is drawn now (followed during
    // the flight: the notch may still be opening), at its size.
    const isl = this.island();
    const home = this.homeSpot(isl);
    this.spread = true;
    this.refresh();
    this.emitPage("desktop-flight", "home");
    let done = true;
    if (home) {
      const last = { pos: home.pos, scale: home.scale };
      const now = () => {
        const h = this.homeSpot(this.island());
        if (h) { last.pos = h.pos; last.scale = h.scale; }
        return last;
      };
      done = await this.fly(() => now().pos, FLIGHT_MS, easeInOut, () => now().scale);
    }
    // Port: Robo goes on as the island's, mid-glance (the same sim).
    if (done) this.page?.handBack();
    if (done) {
      // The island shows its the mascot once this resolves (setAway(false)): he
      // stays a moment longer, on top of it, so no frame is without him.
      const token = this.flight;
      setTimeout(() => {
        if (this.flight === token && this.shown && !this.landed && !this.carry && !this.dragging) this.hide();
      }, 80);
    }
    if (forget) this.remember({ onDesktop: false });
    return done;
  }

  setAsleep(asleep: boolean) {
    const changed = this.asleep !== asleep;
    this.asleep = asleep;
    if (changed) this.refresh();
  }

  /** The cursor poll (global logical px), only while cursorActive: his eyes and the sleep rule. */
  cursorAt(g: Point) {
    if (!this.eyesActive) return;
    this.emitPage(DESKTOP_EVENTS.cursor, { x: g.x - this.pos.x, y: g.y - this.pos.y });
  }

  /** Displays came or went: if his display is gone, he sits in the island display's corner (spot kept). */
  screensChanged() {
    if (!this.shown || !this.landed || this.spread || this.flying || this.dragging) {
      this.refresh();
      return;
    }
    const all = this.all();
    const c = centreOf(this.pos);
    const here = all.find((s) => contains(s.frame, c));
    if (here && here.name === this.smallScreen) {
      this.refresh();
      return;
    }
    const isl = this.island();
    const d = here ?? isl;
    if (!d) {
      this.refresh();
      return;
    }
    this.place(here ? clampOrigin(this.pos, SIZE, d.frame, MARGIN) : defaultSpot(asDisplay(d), SIZE, MARGIN));
    this.land();
  }
}

// ── The page (desktop/main.ts, class DesktopMascot) ───────────────────────────

/** Width the mascot is drawn at (DRAW_W) and the margin each side (SIDE). */
export const DRAW_W = PANEL_SIZE * 0.8;
export const SIDE = (PANEL_SIZE - DRAW_W) / 2;
export const AWAKE_FRAME_MS = 1000 / 30;
export const ASLEEP_FRAME_MS = 250;

/** What the page needs from QML. */
export interface PageHost {
  /** Event to the island page (emitToWindow(ISLAND, …)). */
  emitIsland(name: string, payload?: unknown): void;
  /** The window's current width (window.innerWidth), for the layer drag. */
  windowWidth(): number;
  /** Visibility / sleep / offset changed: re-read them (frame timer, canvas position). */
  changed(): void;
  /** The canvas fades in (opacity 0 → 1, 0.45 s ease-in-out). */
  fadeIn(): void;
}

export class DesktopPage {
  readonly engine = new BotEngine();
  mode: "layer" | "off" = "off";
  /** The port's addition: a global cursor feeds his eyes (upstream mode === "poll"). */
  cursorPoll = true;

  snap: DesktopSnapshot = {
    state: "idle", outfit: "none" as never, soundEnabled: true, soundVolume: 0.12, paused: false, dancing: false,
  };

  visible = false;
  asleep = false;
  informed = false;
  lastAgentActive = performance.now();
  cursor: Point | null = null;
  lastPointer = -Infinity;
  lastDraw = 0;

  /** Canvas offset inside the window. Always 0 here: the shell maps the mouse to his box. */
  offset: Point = { x: 0, y: 0 };
  press: { client: Point; screen: Point } | null = null;
  dragging = false;
  private pokeTimer: number | null = null;

  private host: PageHost;
  private win: DesktopWindow | null;
  /** Port (his ask): Robo on the desktop while Settings choose him. */
  robot: Robot | null = null;
  /** Port: set by the engine's onDizzy during a poke (the island does the dizzy). */
  private wentDizzy = false;

  constructor(host: PageHost, win: DesktopWindow | null) {
    this.host = host;
    this.win = win;
    if (win) win.page = this;
    this.engine.particleOverhang = 0;
    this.engine.setState("idle", true);
    this.engine.onDizzy = () => {
      this.wentDizzy = true;
      this.host.emitIsland(DESKTOP_EVENTS.dizzy);
    };
  }

  start(mode: "layer" | "off" = "layer") {
    this.mode = mode;
    this.host.emitIsland(DESKTOP_EVENTS.ready);
  }

  /** emitToWindow("mascot", name, payload) from the island, and the window's events. */
  onEvent(name: string, payload: any) {
    switch (name) {
      case DESKTOP_EVENTS.state:
        this.onSnapshot(payload);
        break;
      case DESKTOP_EVENTS.emote:
        this.lastAgentActive = performance.now();
        this.wake();
        this.engine.triggerEmote(payload.emote as BotEmoteName, payload.duration);
        break;
      case DESKTOP_EVENTS.cursor:
        this.notePointer(payload);
        break;
      case DESKTOP_EVENTS.visible:
        this.setVisible(!!payload);
        break;
      case DESKTOP_EVENTS.flight:
        if (payload === "out") {
          this.host.fadeIn();
          this.takeOver();
        }
        break;
    }
  }

  // ── State ───────────────────────────────────────────────────────────────────

  onSnapshot(s: DesktopSnapshot) {
    this.snap = s;
    this.informed = true;
    Sound.setEnabled(s.soundEnabled);
    Sound.setVolume(s.soundVolume);
    if (agentActive(s.state)) this.lastAgentActive = performance.now();
    if (!this.asleep) this.engine.setState(s.state);
    this.updateSleep(performance.now());
  }

  setVisible(on: boolean) {
    this.visible = on;
    if (on) {
      if (!this.informed) this.host.emitIsland(DESKTOP_EVENTS.ready);
      this.lastAgentActive = performance.now();
      this.asleep = false;
      this.engine.setState(this.snap.state, true);
      this.engine.setOutfit(this.snap.outfit, false);
      this.host.changed();
      return;
    }
    this.cancelPoke();
    this.press = null;
    this.dragging = false;
    this.setOffset({ x: 0, y: 0 });
    Sound.idle();
    this.host.changed();
  }

  updateSleep(now: number) {
    if (!this.visible) return;
    if (this.snap.dancing && !this.snap.paused) this.lastAgentActive = now;
    const distance = pointerDistance(this.cursorPoll, this.cursor, now - this.lastPointer);
    const sleep = !this.dragging && (this.snap.paused || shouldSleep((now - this.lastAgentActive) / 1000, distance));
    if (sleep === this.asleep) return;
    this.asleep = sleep;
    this.engine.setState(sleep ? "sleeping" : this.snap.state);
    this.win?.setAsleep(sleep);
    if (sleep) Sound.idle();
    this.host.changed();
  }

  wake() {
    if (!this.asleep) return;
    this.updateSleep(performance.now());
  }

  notePointer(p: Point) {
    this.cursor = p;
    this.lastPointer = performance.now();
    if (this.asleep) this.wake();
  }

  // ── Frames (the QML timer calls step(), then the canvas paints) ─────────────

  get frameInterval(): number {
    return this.asleep ? ASLEEP_FRAME_MS : AWAKE_FRAME_MS;
  }

  /** frame(): sleep, then draw()'s engine half. False when not visible. */
  step(now: number): boolean {
    if (!this.visible) return false;
    const dt = Math.min(0.05, Math.max(0, (now - this.lastDraw) / 1000));
    this.lastDraw = now;
    this.updateSleep(now);
    const engine = this.engine;
    engine.setOutfit(this.snap.outfit, true);
    // Port: he wears the island the mascot's colour on the desktop too (Claude's
    // orange on the Claude Code pill, a helper's own).
    engine.bodyColor = islandNow ? islandNow.engine.bodyColor : null;
    if (!this.asleep) {
      const fresh = this.cursorPoll || now - this.lastPointer < 1500;
      const g = this.cursor && fresh ? gaze(lookOrigin(0, 0), this.cursor) : { lookX: 0, lookY: 0 };
      engine.lookX = g.lookX;
      engine.lookY = g.lookY;
    }
    engine.setDancing(this.snap.dancing && !this.asleep);
    engine.update(dt);
    this.stepRobot(dt, engine.lookX, engine.lookY);
    return true;
  }

  /**
   * Port (his ask): one Robo, not two. Flying out, the desktop's takes the
   * island's sim (pose, face, springs) so he leaves as he was; landing,
   * handBack() gives it back. In between the island's runs on a new one.
   */
  takeOver() {
    const isl = islandNow?.robot;
    if (!Robo.isRobo() || !isl) return;
    if (!this.robot) this.robot = new Robot(Robo.mainLook(), DRAW_W, 0.53);
    this.robot.sim = isl.sim;
    isl.sim = new RobotSim(0.37, isl.state);
    isl.sim.age = 10;
  }

  handBack() {
    const isl = islandNow?.robot;
    if (!this.robot || !isl || !Robo.isRobo()) return;
    // Shared for the moment both show him; the island steps it from now on.
    isl.sim = this.robot.sim;
  }

  /** Port (his ask): the desktop's Robo, as the island's: its state (searching
   *  when the work is a search or a read), asleep with the page, eyes on the cursor. */
  private stepRobot(dt: number, lookX: number, lookY: number) {
    if (!Robo.isRobo()) {
      this.robot = null;
      return;
    }
    const look = Robo.mainLook();
    if (!this.robot) this.robot = new Robot(look, DRAW_W, 0.53);
    const r = this.robot;
    r.setLook(look);
    r.setBox(DRAW_W);
    const state = Robo.robotState(this.snap.state, false, State.stateOverride ? null : State.focusTask);
    r.setState(this.asleep ? "sleeping" : state);
    // Eyes on the cursor as the island's are: its offset from his centre, px.
    const fresh = this.cursor && (this.cursorPoll || performance.now() - this.lastPointer < 1500);
    const c = lookOrigin(0, 0);
    r.look_at(this.asleep ? null : fresh && this.cursor ? { x: this.cursor.x - c.x, y: this.cursor.y - c.y } : { x: lookX * 240, y: -lookY * 180 });
    // (Once handed back, the island steps the shared sim.)
    if (islandNow?.robot?.sim !== r.sim) r.update(dt);
  }

  /** draw()'s canvas half, on a CtxWrap over a PANEL_SIZE square canvas. */
  paint(ctx: CanvasRenderingContext2D, top = 0) {
    // (Port: `top` px of canvas above his box, and as many below it.)
    ctx.setTransform(1, 0, 0, 1, SIDE, top);
    ctx.clearRect(-SIDE, -top, PANEL_SIZE, PANEL_SIZE + 2 * top);
    if (this.robot && Robo.isRobo()) {
      // His head's box centred where the mascot's body is (the canvas's middle):
      // flights to and from the island line up those centres, and the
      // island's Robo is centred on its mascot's the same way.
      this.robot.drawAt(ctx, 0, (PANEL_SIZE - DRAW_W) / 2 + DRAW_W * 0.018);
      return;
    }
    ctx.save();
    this.engine.applyDance(ctx, DRAW_W, PANEL_SIZE);
    this.engine.draw(ctx, DRAW_W, PANEL_SIZE);
    ctx.restore();
  }

  // ── Input (window coordinates, as clientX / clientY) ────────────────────────

  private local(x: number, y: number): Point {
    return { x: x - this.offset.x, y: y - this.offset.y };
  }

  /** Whether a press at (x, y) is his (the page's hit test). */
  hit(x: number, y: number): boolean {
    return isOverBody(this.local(x, y));
  }

  pointerDown(x: number, y: number, button: number, screenX: number, screenY: number) {
    Sound.resume();
    if (button !== 0 || !isOverBody(this.local(x, y))) return;
    this.press = { client: this.local(x, y), screen: { x: screenX, y: screenY } };
    this.dragging = false;
  }

  pointerMove(x: number, y: number) {
    if (!this.dragging) this.notePointer(this.local(x, y));
    const press = this.press;
    if (!press) return;
    if (!this.dragging) {
      const l = this.local(x, y);
      if (Math.hypot(l.x - press.client.x, l.y - press.client.y) <= DRAG_THRESHOLD) return;
      this.beginDrag();
    }
    this.dragTo(x, y);
  }

  pointerUp(x: number, y: number) {
    const press = this.press;
    this.press = null;
    if (!press) return;
    if (this.dragging) {
      this.endDrag(x, y);
      return;
    }
    this.cancelPoke();
    this.pokeTimer = setTimeout(() => {
      this.pokeTimer = null;
      this.poke();
    }, DOUBLE_CLICK_MS) as unknown as number;
  }

  /** The poke itself (also the harness's way in). */
  poke() {
    this.lastAgentActive = performance.now();
    this.wake();
    const wasDizzy = this.engine.state === "dizzy";
    this.wentDizzy = false;
    this.engine.slap();
    // Robo: a bounce; the third poke (the mascot's dizzy) spins him, error face at once.
    if (this.robot && Robo.isRobo() && !wasDizzy) {
      if (this.wentDizzy) this.robot.dizzy();
      else this.robot.click();
    }
  }

  doubleClick(x: number, y: number) {
    if (!isOverBody(this.local(x, y))) return;
    this.cancelPoke();
    this.host.emitIsland(DESKTOP_EVENTS.home);
  }

  contextMenu(x: number, y: number) {
    if (isOverBody(this.local(x, y))) this.host.emitIsland(DESKTOP_EVENTS.wardrobe);
  }

  pointerLeave() {
    if (!this.cursorPoll && !this.dragging) this.cursor = null;
  }

  /** window "resize": back to his own size, so is the canvas. */
  resized() {
    if (!this.dragging && this.host.windowWidth() <= PANEL_SIZE + 20) this.setOffset({ x: 0, y: 0 });
  }

  cancelPoke() {
    if (this.pokeTimer != null) clearTimeout(this.pokeTimer);
    this.pokeTimer = null;
  }

  private beginDrag() {
    this.dragging = true;
    this.cancelPoke();
    // Upstream asks the window to cover the display and moves the canvas in
    // it; here the window moves him (global cursor, onto any display).
    if (!this.press || !this.win || !this.win.dragBegin(this.press.client)) {
      this.dragging = false;
      this.press = null;
    }
  }

  private dragTo(x: number, y: number) {
    if (!this.press || this.mode !== "layer") return;
    this.win?.dragMove(this.local(x, y));
  }

  private endDrag(x: number, y: number) {
    this.dragging = false;
    if (this.win) void this.win.dragEnd(this.local(x, y));
  }

  /** The grab was taken from his window (no release will come): the drop is where the cursor is. */
  cancelDrag() {
    const was = this.dragging;
    this.press = null;
    this.dragging = false;
    if (was && this.win) void this.win.dragEnd(null);
  }

  private setOffset(p: Point) {
    this.offset = p;
    this.host.changed();
  }
}

/** One window + page pair, wired together. */
export function create(winHost: WindowHost, pageHost: PageHost): { win: DesktopWindow; page: DesktopPage } {
  const win = new DesktopWindow(winHost);
  const page = new DesktopPage(pageHost, win);
  return { win, page };
}
