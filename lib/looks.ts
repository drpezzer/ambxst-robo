// Port only (his ask): each chat has its own look. Settings → Style are the
// DEFAULTS a new chat starts from (each customisation can be randomised per
// new chat instead); the wardrobe (right click on the notch, a chat in front)
// changes that one chat. Kept in settings.chatLooks by the chat's durable key
// (its chats-column card, "kind:id"), or by its conversation id until it has
// one. A chat seen before this existed gets its look the first time it shows.

import { Bridge } from "@coucou/core/bridge";
import { State } from "@coucou/core/state";
import { OUTFIT_SELECTIONS } from "@coucou/mascot/wardrobe";
import { prefs as roboPrefs } from "./robot/config";
import { SHAPES, brandLook, type RobotLook } from "./robot/mascot";
import { PUBLIC, currentMascot, defaultMascot, mascotOf } from "./mascots";

export { PUBLIC, currentMascot, defaultMascot, mascotOf };

export interface RoboColors { shell: string; trim: string; screen: string }
export interface ChatLook {
  /** "" = the agent's colour (Claude's orange). */
  coucou: { color: string; outfit: string };
  /** colors null = the agent's brand colours. */
  robo: { shape: string; antenna: boolean; colors: RoboColors | null };
  ambxst: { color: string };
}

/** The swatches (the robot-heads playground's, and the same for the Coucou mascot and Axenide). */
export const SHELL = ["#2b49a3", "#c8382f", "#e0782a", "#e3b22b", "#2f8f57", "#1f8a8a", "#6c4bc4", "#d9558c", "#3a3d44", "#e6e8ec"];
export const TRIM = ["#93a6c8", "#c9ccd2", "#c9a24e", "#c27a52", "#2b2d31"];
export const SCREEN = ["#e8f2ff", "#7fe7ff", "#8cff9e", "#ffc46b", "#ff8fc8"];
export const BODY = ["#D97757", "#c8382f", "#e3b22b", "#2f8f57", "#1f8a8a", "#2b49a3", "#6c4bc4", "#d9558c", "#e6e8ec", "#3a3d44"];

type Settings = {
  mascot?: string;
  mascotOutfit?: string;
  coucouColor?: string;
  ambxstColor?: string;
  lookRandom?: Record<string, boolean>;
  chatLooks?: Record<string, ChatLook>;
};
const S = () => State.settings as unknown as Settings;

/** Which customisations are randomised per new chat (Settings → Style). */
export function randomised(what: string): boolean {
  return !!S().lookRandom?.[what];
}

const pick = <T>(a: readonly T[]): T => a[Math.floor(Math.random() * a.length)];

/** A new chat's look: the defaults, the randomised parts drawn now. */
export function fresh(): ChatLook {
  const s = S();
  const r = roboPrefs();
  const outfits = (OUTFIT_SELECTIONS as readonly string[]).filter((o) => o !== "auto" && o !== "none");
  return {
    coucou: {
      color: randomised("coucouColor") ? pick(BODY) : s.coucouColor || "",
      // Port: the public build has no outfits (lib/public/wardrobe.ts).
      outfit: PUBLIC ? "none" : randomised("mascotOutfit") && outfits.length ? pick(outfits) : s.mascotOutfit || "auto",
    },
    robo: {
      shape: randomised("roboShape") ? pick(SHAPES) : r.shape,
      antenna: randomised("roboAntenna") ? Math.random() < 0.5 : r.antenna,
      colors: randomised("roboColors")
        ? { shell: pick(SHELL), trim: pick(TRIM), screen: pick(SCREEN) }
        : r.customColors ? { shell: r.shell, trim: r.trim, screen: r.screen } : null,
    },
    ambxst: { color: randomised("ambxstColor") ? pick(BODY) : s.ambxstColor || "" },
  };
}

/** Looks made this session for chats not kept yet (no key, never edited). */
const pending = new Map<string, ChatLook>();
/** conv id → its durable key, as the chat view learns them. */
const keys = new Map<string, string>();

function storeKey(conv: string): string {
  return keys.get(conv) ?? conv;
}

/** The chat `conv`'s look (made on first sight). */
export function of(conv: string): ChatLook {
  const k = storeKey(conv);
  const kept = S().chatLooks?.[k] ?? S().chatLooks?.[conv];
  if (kept) return kept;
  let p = pending.get(conv);
  if (!p) {
    p = fresh();
    pending.set(conv, p);
  }
  return p;
}

function save() {
  void Bridge.saveSettings(State.settings);
}

/** The chat view learned `conv`'s durable key: its look is kept under it. */
export function noteKey(conv: string, key: string | null) {
  if (!key || keys.get(conv) === key) return;
  keys.set(conv, key);
  const s = S();
  const looks = (s.chatLooks ??= {});
  if (looks[key]) {
    // Seen before (a reload): that look stands.
    pending.delete(conv);
    if (looks[conv]) { delete looks[conv]; save(); }
    return;
  }
  const look = looks[conv] ?? pending.get(conv);
  if (!look) return;
  looks[key] = look;
  delete looks[conv];
  pending.delete(conv);
  save();
  State.notify();
}

/** The wardrobe changed `conv`'s look. */
export function edit(conv: string, fn: (l: ChatLook) => void) {
  const look = JSON.parse(JSON.stringify(of(conv))) as ChatLook;
  fn(look);
  (S().chatLooks ??= {})[storeKey(conv)] = look;
  pending.delete(conv);
  save();
  State.notify();
}

/** The conversation a pill stands for, or null (chat.ts convPillId `agent_c-…`). */
export function convOfTask(task: { id: string; conv?: string } | null | undefined): string | null {
  if (!task) return null;
  if (task.conv) return task.conv;
  return task.id.startsWith("agent_c-") ? task.id.slice("agent_".length) : null;
}

/** The chat in front (its pill focused), or null: the main bot. */
export function frontConv(): string | null {
  return convOfTask(State.focusTask as { id: string; conv?: string } | null);
}

/** Port: Settings' mascot, resolved (lib/mascots.ts: Axenide by default in the public build). */
const mascot = () => currentMascot();

/** The body colour (hex) a chat's Coucou mascot / Axenide wears, its agent's colour by default. */
export function bodyHex(conv: string | null, agentColor: string): string {
  if (!conv) {
    const d = mascot() === "ambxst" ? S().ambxstColor : S().coucouColor;
    return d || agentColor;
  }
  const l = of(conv);
  return (mascot() === "ambxst" ? l.ambxst.color : l.coucou.color) || agentColor;
}

/** A chat's Coucou mascot outfit selection. */
export function outfitOf(conv: string): string {
  return of(conv).coucou.outfit || "auto";
}

/** A chat's Robo head. */
export function roboLook(conv: string, agentColor: string): RobotLook {
  const l = of(conv).robo;
  const r = roboPrefs();
  const colors = l.colors ?? brandLook(agentColor || "#D97757");
  return { shape: (SHAPES as readonly string[]).includes(l.shape) ? l.shape as RobotLook["shape"] : r.shape, antenna: l.antenna, speed: r.speed, ...colors };
}

/** The colour a look stands for (its glow): what its mascot wears. */
function colorOfLook(l: ChatLook, agentColor: string): string {
  if (mascot() === "robo") return l.robo.colors?.shell ?? agentColor;
  return (mascot() === "ambxst" ? l.ambxst.color : l.coucou.color) || agentColor;
}

/** The colour a chat stands for (its glow): what its mascot wears. */
export function chatColor(conv: string, agentColor: string): string {
  return colorOfLook(of(conv), agentColor);
}

/** The same for a chats-column card ("kind:id"): its chat's colour, if it has a look. */
export function colorForKey(key: string, agentColor: string): string {
  let l: ChatLook | undefined = S().chatLooks?.[key];
  if (!l) for (const [conv, k] of keys) if (k === key) { l = of(conv); break; }
  return l ? colorOfLook(l, agentColor) : agentColor;
}
