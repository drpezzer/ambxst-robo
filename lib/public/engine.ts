// Port (public build): the mascots' engine without the Coucou mascot. lib/build.mjs
// resolves every `mascot/engine` import to this file for `--public`, so the
// island, the minis, the desktop page, the palette and the recap image all run
// on it. It keeps BotEngine's API (what the rest of the port calls: states,
// slaps and dizzy, emotes, eye overrides, gaze, squash, the file-drop morph and
// slot, dancing, body colour, the state colour table palette.ts recolours) and
// written from scratch: its own motions, and no drawing of its own: what it
// draws is Axenide (lib/ambxst/standalone.ts). Robo draws himself (lib/robot)
// and only rides its state, emotes and gaze.

import { Ease, lerp, type EaseFn } from "@coucou/core/anim";
import { Sound } from "@coucou/core/sound";
import type { BotEmoteName, BotStateName } from "@coucou/core/layout";
import { drawAxenide, drawAxenideBadge, drawAxenideParticles } from "../ambxst/standalone";

// ── Types ─────────────────────────────────────────────────────────────────────

/** Expression names (core/state.ts keeps one per mini: AgentTask.miniEye). */
export type EyeShape =
  | "pill" | "wide" | "dot" | "line" | "flat" | "happy" | "closed"
  | "spiral" | "heart" | "star" | "tired" | "wink" | "cup";

export type BadgeKind = "dots" | "bang" | "question" | "dot";

/** A colour, components 0…1. */
export type RGB = readonly [number, number, number];

export interface Badge {
  kind: BadgeKind;
  color: RGB;
}

export type TweenKey = readonly [target: number, durationMs: number, ease: EaseFn];

type Prop =
  | "yaw" | "pitch" | "roll" | "tilt" | "open" | "sx" | "sy"
  | "oy" | "ox" | "tint" | "morph" | "blush" | "es" | "badgeS";

interface Tween {
  keys: TweenKey[];
  index: number;
  from: number;
  startMs: number;
  done?: () => void;
}

export interface StateLook {
  color: RGB;
  /** How much of the state's colour washes over the body, 0…1. */
  tint: number;
  eye: EyeShape;
  badge: Badge | null;
  hops: boolean;
  scans: boolean;
  breathes: boolean;
  snores: boolean;
  sweats: boolean;
  look: readonly [number, number] | null;
  tilt: number;
}

export type ParticleKind = "love" | "sparkle" | "spark" | "drop" | "sleep";

export interface Particle {
  kind: ParticleKind;
  x: number; y: number; vx: number; vy: number;
  age: number; life: number; spin: number; size: number;
}

// ── State colours (Coucou's state palette, core/layout.ts botGlowColor) ──────

const COLOR: Record<string, [number, number, number]> = {
  idle: [0.902, 0.914, 0.933],
  working: [0.231, 0.62, 1],
  thinking: [0.545, 0.361, 0.965],
  searching: [0.388, 0.396, 0.949],
  approval: [0.961, 0.647, 0.141],
  question: [0.133, 0.827, 0.933],
  error: [0.957, 0.314, 0.369],
  finished: [0.204, 0.831, 0.6],
  ratelimit: [0.984, 0.573, 0.235],
  sleeping: [0.58, 0.635, 0.722],
  dizzy: [0.957, 0.447, 0.714],
};

function look(s: string, eye: EyeShape, tint: number, badge: BadgeKind | null, extra: Partial<StateLook> = {}): StateLook {
  // The badge shares the state's colour array: palette.ts recolours both at once.
  return {
    color: COLOR[s], tint, eye, badge: badge ? { kind: badge, color: COLOR[s] } : null,
    hops: false, scans: false, breathes: false, snores: false, sweats: false, look: null, tilt: 0,
    ...extra,
  };
}

/** Each state's look (palette.ts reads and recolours the colours in place). */
export const BOT_STATES: Record<BotStateName, StateLook> = {
  idle: look("idle", "pill", 0, null),
  working: look("working", "pill", 0.7, "dots"),
  thinking: look("thinking", "pill", 0.7, "dots", { look: [0.5, 0.6] }),
  searching: look("searching", "pill", 0.7, "dots", { scans: true }),
  approval: look("approval", "wide", 0.75, "bang", { hops: true }),
  question: look("question", "pill", 0.72, "question", { tilt: -0.15 }),
  error: look("error", "flat", 0.75, "dot"),
  finished: look("finished", "happy", 0.35, "dot"),
  ratelimit: look("ratelimit", "tired", 0.7, "dot", { sweats: true }),
  sleeping: look("sleeping", "closed", 0.3, null, { breathes: true, snores: true }),
  dizzy: look("dizzy", "spiral", 0.7, null),
};

/** State → sound (the Sound module's names). */
export const STATE_SOUND: Partial<Record<BotStateName, string>> = {
  working: "work", thinking: "think", searching: "search", approval: "approval",
  question: "question", error: "error", finished: "finish", ratelimit: "rate",
  sleeping: "sleep", dizzy: "dizzy",
};

const EMOTE_EYE: Record<BotEmoteName, EyeShape> = {
  love: "heart", surprised: "dot", proud: "star", wink: "wink",
  yawn: "tired", happy: "happy", annoyed: "line",
};

// ── Helpers ───────────────────────────────────────────────────────────────────

const now = () => performance.now() / 1000;

export function hexToRGB(hex: string): RGB {
  const v = parseInt(hex.replace("#", "").slice(0, 6), 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
}

const approach = (v: number, to: number, k: number) => v + (to - v) * k;

// ── Dancing ───────────────────────────────────────────────────────────────────

/** The dance level eases toward 1 while dancing (0.25 s) and back to 0 (0.45 s). */
export function stepDanceLevel(level: number, dancing: boolean, dt: number): number {
  if (dancing) return Math.min(1, level + dt / 0.25);
  return Math.max(0, level - dt / 0.45);
}

/** The groove at `seconds` for a body of size R: a bob on the beat, a lean, a squash at the bottom. */
export function danceTransform(seconds: number, level: number, R: number) {
  const beat = (seconds * 116) / 60;
  const swing = Math.sin(Math.PI * beat);
  const up = Math.pow(Math.abs(swing), 0.8);
  const low = Math.pow(1 - Math.abs(swing), 4);
  return {
    dx: 0.06 * R * Math.sin(Math.PI * beat * 0.5) * level,
    dy: -0.16 * R * up * level,
    rotate: 0.07 * swing * level,
    sx: 1 + 0.05 * low * level,
    sy: 1 - 0.05 * low * level,
  };
}

// ── Engine ────────────────────────────────────────────────────────────────────

export class BotEngine {
  isMini = false;
  /** Solid body colour (a mini's, a chat's), or null for the default. */
  bodyColor: RGB | null = null;
  /** Port: a Settings card's own mascot, whatever Settings say. */
  mascotOverride?: string;

  // Animated values.
  yaw = 0; pitch = 0; roll = 0; tilt = 0; open = 1;
  sx = 1; sy = 1; oy = 0; ox = 0;
  tint = 0; morph = 0; blush = 0; es = 1; badgeS = 0;
  /** Kept for the API: the public build has no hands. */
  hands = 0;

  // No outfits in the public build: setOutfit() is a no-op.
  outfit = "none";
  outfitPresence = 0;

  // Where the animated values drift to.
  tgYaw = 0; tgPitch = 0; tgTilt = 0; tgSy = 1; tgSx = 1; tgEs = 1;

  /** Extra canvas height above the body for particles. */
  particleOverhang = 0;

  isDancing = false;
  dancingLevel = 0;

  // The slot (the file drop), a spring, in fractions of R.
  slotH = 0; slotHTarget = 0; slotHVel = 0; isChewing = false;

  col: RGB = COLOR.idle;
  colT: RGB = COLOR.idle;

  state: BotStateName = "idle";
  cfg: StateLook = BOT_STATES.idle;

  eyeOverride: EyeShape | null = null;
  eyeOverrideUntil = 0;
  permanentEye: EyeShape | null = null;
  permanentEmote: BotEmoteName | null = null;
  miniNextBehavior = 0;

  badge: Badge | null = null;
  private badgeKey = "none";
  private badgeToken = 0;

  private tweens = new Map<Prop, Tween>();
  particles: Particle[] = [];

  lookX = 0;
  lookY = 0;

  lastTime = now();
  private t0 = now() - Math.random() * 6;
  private nextBlink = now() + 1.2 + Math.random() * 2.4;
  private lastAmbient = 0;
  private slaps: number[] = [];
  private wander = { x: 0, y: 0, next: 0 };

  /** Three slaps inside 1.7 s: dizzy (the island opens its confused view). */
  onDizzy: (() => void) | null = null;

  // ── State ───────────────────────────────────────────────────────────────────

  setState(next: BotStateName, force = false) {
    if (this.state === next && !force) return;
    const prev = this.state;
    this.state = next;
    this.cfg = BOT_STATES[next] ?? BOT_STATES.idle;
    this.colT = this.cfg.color;
    if (!this.tweens.has("tint")) this.tint = this.cfg.tint;
    if (!this.tweens.has("tilt")) this.tgTilt = this.cfg.tilt;
    this.setBadge(this.cfg.badge);

    switch (next) {
      case "finished":
        this.anim("oy", [[-0.18, 160, Ease.out], [0, 320, Ease.back]]);
        setTimeout(() => this.emit("sparkle", 4), 380);
        break;
      case "error":
        this.anim("ox", [[0.07, 50, Ease.out], [-0.07, 70, Ease.inOut], [0.04, 70, Ease.inOut], [0, 90, Ease.out]]);
        break;
      case "approval":
        this.anim("oy", [[-0.16, 140, Ease.out], [0, 300, Ease.back]]);
        break;
      case "dizzy":
        this.spin(1200, 1);
        break;
      case "ratelimit":
        this.emit("drop", 1);
        break;
      default:
        if (prev !== "idle" || next !== "idle") this.blink();
    }
  }

  setBadge(b: Badge | null) {
    const key = b ? `${b.kind}-${b.color.join(",")}` : "none";
    if (key === this.badgeKey) return;
    this.badgeKey = key;
    const tok = ++this.badgeToken;
    this.anim("badgeS", [[0, 100, Ease.inOut]]);
    setTimeout(() => {
      if (tok !== this.badgeToken) return;
      this.badge = b;
      if (b) this.anim("badgeS", [[1, 260, Ease.back]]);
    }, 110);
  }

  // ── Motions ─────────────────────────────────────────────────────────────────

  blink() {
    if (this.tweens.has("open")) return;
    this.anim("open", [[0.08, 60, Ease.inOut], [1, 140, Ease.out]]);
  }

  squash() {
    this.anim("sy", [[0.8, 80, Ease.out], [1.08, 140, Ease.out], [1, 180, Ease.inOut]]);
    this.anim("sx", [[1.14, 80, Ease.out], [0.96, 140, Ease.out], [1, 180, Ease.inOut]]);
  }

  /** The file drop: the slot opens, takes the file, closes, a chew. */
  gulp() {
    this.slotHTarget = 0.4;
    setTimeout(() => {
      this.slotHTarget = 0;
      this.isChewing = true;
      setTimeout(() => { this.isChewing = false; }, 750);
    }, 480);
    this.anim("sy", [[0.82, 90, Ease.out], [1.14, 140, Ease.out], [1, 240, Ease.back]]);
    this.anim("sx", [[1.22, 90, Ease.out], [0.94, 140, Ease.out], [1, 240, Ease.back]]);
    this.blink();
  }

  slap() {
    if (this.state === "dizzy") return;
    const t = now();
    this.slaps = this.slaps.filter((s) => t - s < 1.7);
    this.slaps.push(t);
    Sound.play("slap");
    this.squash();
    if (this.slaps.length >= 3) {
      this.slaps = [];
      this.onDizzy?.();
    } else {
      this.eyeOverride = "line";
      this.eyeOverrideUntil = t + 0.8;
      setTimeout(() => Sound.play("annoyed"), 60);
    }
  }

  /** A whole-body spin (the figure turns as one piece). */
  spin(durationMs: number, turns: number) {
    this.roll = 0;
    this.anim("roll", [[Math.PI * 2 * turns, durationMs, Ease.inOut]], () => { this.roll = 0; });
  }

  /** Kept for the API (the island's slap stops a wave): nothing to stop here. */
  interruptGreet() {}

  /** A small hello: happy eyes and a hop (no hands in the public build). */
  greet() {
    this.eyeOverride = "happy";
    this.eyeOverrideUntil = now() + 1.6;
    this.anim("oy", [[-0.14, 200, Ease.out], [0, 280, Ease.back]]);
    setTimeout(() => Sound.play("greet"), 200);
  }

  setPermanentEmote(emote: BotEmoteName | null) {
    this.permanentEmote = emote;
    const n = now();
    this.miniNextBehavior = n + 0.8 + Math.random() * 1.6;
    if (emote === "wink") return;
    this.permanentEye = emote ? EMOTE_EYE[emote] : null;
    if (this.permanentEye) {
      this.eyeOverride = this.permanentEye;
      this.eyeOverrideUntil = Number.POSITIVE_INFINITY;
    } else if (this.eyeOverrideUntil === Number.POSITIVE_INFINITY) {
      this.eyeOverride = null;
      this.eyeOverrideUntil = 0;
    }
  }

  triggerEmote(emote: BotEmoteName, duration = 1.8) {
    const t = now();
    this.eyeOverride = EMOTE_EYE[emote];
    this.eyeOverrideUntil = t + duration;
    const holdMs = (s: number) => Math.max(0, (duration - s) * 1000);
    switch (emote) {
      case "love":
        this.anim("blush", [[1, 280, Ease.out], [1, holdMs(0.6), Ease.lin], [0, 320, Ease.inOut]]);
        this.emit("love", 3);
        this.anim("oy", [[-0.09, 150, Ease.out], [0, 280, Ease.back]]);
        break;
      case "surprised":
        this.anim("oy", [[-0.25, 130, Ease.out], [0, 360, Ease.back]]);
        this.anim("es", [[1.2, 110, Ease.out], [1, 480, Ease.inOut]]);
        break;
      case "proud":
        this.emit("sparkle", 4);
        this.anim("tilt", [[-0.12, 200, Ease.out], [-0.12, holdMs(0.5), Ease.lin], [0, 300, Ease.inOut]]);
        this.anim("blush", [[0.6, 240, Ease.out], [0.6, holdMs(0.5), Ease.lin], [0, 300, Ease.inOut]]);
        break;
      case "wink":
        this.anim("tilt", [[0.1, 150, Ease.out], [0.1, holdMs(0.4), Ease.lin], [0, 250, Ease.inOut]]);
        break;
      case "yawn":
        this.anim("sy", [[1.1, 480, Ease.inOut], [1, 520, Ease.inOut]]);
        this.anim("sx", [[0.95, 480, Ease.inOut], [1, 520, Ease.inOut]]);
        setTimeout(() => { this.eyeOverride = "closed"; this.emit("sleep", 2); }, 650);
        break;
      case "happy":
        this.anim("blush", [[0.55, 200, Ease.out], [0, 600, Ease.inOut]]);
        break;
      case "annoyed":
        this.eyeOverride = "line";
        this.eyeOverrideUntil = t + 0.8;
        setTimeout(() => Sound.play("annoyed"), 60);
        break;
    }
  }

  emit(kind: ParticleKind, count: number) {
    for (let i = 0; i < count; i++) {
      const sleep = kind === "sleep";
      this.particles.push({
        kind,
        x: (Math.random() - 0.5) * 0.8 + (sleep ? 0.5 : 0),
        y: -0.65 - Math.random() * 0.2,
        vx: (Math.random() - 0.5) * 0.3 + (sleep ? 0.15 : 0),
        vy: -(0.4 + Math.random() * 0.3),
        age: -i * 0.15,
        life: 1.2 + Math.random() * 0.5,
        spin: Math.random() * Math.PI * 2,
        size: 0.14 + Math.random() * 0.07,
      });
    }
  }

  animateMorph(target: number, durationMs?: number) {
    this.anim("morph", [[target, durationMs ?? (target > 0.5 ? 550 : 650), Ease.inOut]]);
  }

  resetMorph() {
    this.tweens.delete("morph");
    this.morph = 0;
  }

  /** No outfits in the public build. */
  setOutfit(_next: string, _animated = true) {}

  get busy(): boolean {
    const c = this.cfg;
    return (
      this.tweens.size > 0 || this.particles.length > 0 ||
      c.hops || c.scans || c.breathes || c.snores || c.sweats ||
      this.isMini || this.isDancing || this.dancingLevel > 0.001 ||
      Math.abs(this.tgYaw - this.yaw) > 0.002 || Math.abs(this.tgPitch - this.pitch) > 0.002 ||
      Math.abs(this.tgTilt - this.tilt) > 0.002 || Math.abs(this.tgSy - this.sy) > 0.002 ||
      Math.abs(this.tgSx - this.sx) > 0.002 || Math.abs(this.tgEs - this.es) > 0.002 ||
      this.slotH > 0.001 || Math.abs(this.slotHVel) > 0.001 ||
      Math.abs(this.col[0] - this.colT[0]) > 0.003 || Math.abs(this.col[1] - this.colT[1]) > 0.003 ||
      Math.abs(this.col[2] - this.colT[2]) > 0.003
    );
  }

  // ── Tweens ──────────────────────────────────────────────────────────────────

  anim(prop: Prop, keys: TweenKey[], done?: () => void) {
    this.tweens.set(prop, { keys, index: 0, from: this[prop], startMs: performance.now(), done });
  }

  // ── Update ──────────────────────────────────────────────────────────────────

  update(dt: number) {
    const n = now();
    const ms = performance.now();

    for (const [prop, tw] of [...this.tweens]) {
      const k = tw.keys[tw.index];
      const p = k[1] > 0 ? Math.min(1, Math.max(0, (ms - tw.startMs) / k[1])) : 1;
      this[prop] = tw.from + (k[0] - tw.from) * k[2](p);
      if (p < 1) continue;
      tw.from = k[0];
      tw.index++;
      tw.startMs = ms;
      if (tw.index >= tw.keys.length) {
        this.tweens.delete(prop);
        tw.done?.();
      }
    }

    const c = this.cfg;
    const t = n - this.t0;
    let ty = this.lookX * 0.6;
    let tp = this.lookY * 0.5;
    if (c.look) { ty = ty * 0.3 + c.look[0] * 0.55; tp = tp * 0.3 + c.look[1] * 0.5; }
    if (c.scans) { ty = Math.sin(t * 2.4) * 0.6; tp = -0.05; }
    if (this.state === "sleeping") { ty = 0; tp = -0.15; }
    if (this.state === "dizzy") ty = Math.sin(t * 8) * 0.3;
    // Minis look around on their own.
    if (this.isMini && !c.look && !c.scans && this.state !== "sleeping" && this.state !== "dizzy") {
      if (n > this.wander.next) {
        this.wander = { x: Math.random() * 1.8 - 0.9, y: Math.random() * 1.1 - 0.55, next: n + 0.6 + Math.random() * 1.6 };
      }
      ty = this.wander.x * 0.6;
      tp = this.wander.y * 0.5;
    }
    this.tgYaw = ty;
    this.tgPitch = tp;
    this.tgTilt = c.tilt;

    const kGen = 1 - Math.pow(0.001, dt);
    const kLook = 1 - Math.pow(0.003, dt);
    const hop = c.hops ? -Math.abs(Math.sin(t * 5)) * 0.07 : 0;
    if (!this.tweens.has("oy")) this.oy = approach(this.oy, hop, kGen);

    const amp = c.breathes ? (this.isMini ? 0.07 : 0.035) : this.isMini ? 0.035 : 0;
    const rate = c.breathes ? 1.7 : 2.1;
    this.tgSy = 1 + Math.sin(t * rate) * amp;
    this.tgSx = 1 - Math.sin(t * rate) * amp * 0.55;

    if (this.isMini && n > this.miniNextBehavior) this.miniBehavior(n);

    if (!this.tweens.has("yaw")) this.yaw = approach(this.yaw, this.tgYaw, kLook);
    if (!this.tweens.has("pitch")) this.pitch = approach(this.pitch, this.tgPitch, kLook);
    if (!this.tweens.has("tilt")) this.tilt = approach(this.tilt, this.tgTilt, kGen);
    if (!this.tweens.has("sy")) this.sy = approach(this.sy, this.tgSy, kGen);
    if (!this.tweens.has("sx")) this.sx = approach(this.sx, this.tgSx, kGen);
    if (!this.tweens.has("es")) this.es = approach(this.es, this.tgEs, kGen);

    const kc = 1 - Math.pow(0.002, dt);
    this.col = [lerp(this.col[0], this.colT[0], kc), lerp(this.col[1], this.colT[1], kc), lerp(this.col[2], this.colT[2], kc)];

    if (n > this.nextBlink) {
      if (this.state !== "sleeping" && this.state !== "dizzy") {
        this.blink();
        if (Math.random() < 0.2) setTimeout(() => this.blink(), 240);
      }
      this.nextBlink = n + 2 + Math.random() * 3.5;
    }

    if (this.eyeOverride && n > this.eyeOverrideUntil) {
      this.eyeOverride = this.permanentEye;
      if (this.permanentEye) this.eyeOverrideUntil = Number.POSITIVE_INFINITY;
    }

    if (n - this.lastAmbient > 1.4) {
      this.lastAmbient = n;
      if (c.snores) this.emit("sleep", 1);
      if (!this.isMini && c.sweats && Math.random() < 0.5) this.emit("drop", 1);
    }

    for (const p of this.particles) p.age += dt;
    this.particles = this.particles.filter((p) => p.age < p.life);

    // The slot: a damped spring (period 0.25 s, damping 0.6).
    const w = (2 * Math.PI) / 0.25;
    this.slotHVel += (w * w * (this.slotHTarget - this.slotH) - 2 * 0.6 * w * this.slotHVel) * dt;
    this.slotH = Math.max(0, this.slotH + this.slotHVel * dt);

    this.dancingLevel = stepDanceLevel(this.dancingLevel, this.isDancing, dt);
    this.lastTime = n;
  }

  /** A mini with a permanent emote acts it out now and then. */
  private miniBehavior(n: number) {
    switch (this.permanentEmote) {
      case "happy":
        if (this.tweens.has("oy")) { this.miniNextBehavior = n + 0.4; return; }
        this.anim("oy", [[-0.26, 130, Ease.out], [0, 260, Ease.back]]);
        this.squash();
        this.miniNextBehavior = n + 2.4 + Math.random() * 1.2;
        break;
      case "annoyed":
        if (this.tweens.has("ox")) { this.miniNextBehavior = n + 0.5; return; }
        this.anim("ox", [[0.08, 60, Ease.out], [-0.08, 90, Ease.inOut], [0.05, 80, Ease.inOut], [0, 120, Ease.out]]);
        this.miniNextBehavior = n + 3.2 + Math.random() * 2.4;
        break;
      case "wink":
        this.eyeOverride = "wink";
        this.eyeOverrideUntil = n + 0.6;
        this.anim("tilt", [[0.11, 110, Ease.out], [0.11, 300, Ease.lin], [0, 220, Ease.inOut]]);
        this.miniNextBehavior = n + 2.4 + Math.random() * 2;
        break;
      case "love":
        this.emit("love", 2);
        this.anim("es", [[1.15, 160, Ease.out], [1, 360, Ease.inOut]]);
        this.miniNextBehavior = n + 2.6 + Math.random() * 1.6;
        break;
      default:
        this.miniNextBehavior = n + 3 + Math.random() * 2;
    }
  }

  // ── Dancing ─────────────────────────────────────────────────────────────────

  setDancing(dancing: boolean) {
    this.isDancing = dancing;
  }

  /** The dance, about the bottom of the body: call on a saved context before draw(), same size. */
  applyDance(x: CanvasRenderingContext2D, W: number, H: number) {
    if (this.dancingLevel <= 0.001) return;
    const R = W * 0.3;
    const px = W / 2 + this.ox * R;
    const py = H / 2 + this.particleOverhang / 2 + this.oy * R + R * 0.94;
    const d = danceTransform(now(), this.dancingLevel, R);
    x.translate(px + d.dx, py + d.dy);
    x.rotate(d.rotate);
    x.scale(d.sx, d.sy);
    x.translate(-px, -py);
  }

  // ── Draw: Axenide (lib/ambxst/standalone.ts) ────────────────────────────────

  /** Draws the mascot into a W × H canvas (CSS px, the DPR already applied). */
  draw(x: CanvasRenderingContext2D, W: number, H: number) {
    drawAxenide(this, x, W, H);
  }

  /** The state badge (a method: the island swaps a helper's colour in). */
  drawBadge(x: CanvasRenderingContext2D, badge: Badge, R: number, cx: number, cy: number) {
    drawAxenideBadge(this, x, badge, R, cx, cy);
  }

  drawParticles(x: CanvasRenderingContext2D, R: number, cx: number, cy: number) {
    drawAxenideParticles(this, x, R, cx, cy);
  }
}
