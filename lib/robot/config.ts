// Port only (his ask): Robo in Coucou — which mascot, what Robo shows for
// Coucou's states, and how each head looks (the island's from Settings →
// Style, a mini's picked once by its id).

import { State } from "@coucou/core/state";
import { t } from "@coucou/i18n/i18n";
import type { BotStateName } from "@coucou/core/layout";
import type { RobotHeadShape, RobotHeadState } from "./types";
import { SHAPES, brandLook, miniLook, type RobotLook } from "./mascot";
import * as Looks from "../looks";
import { currentMascot } from "../mascots";

/** Settings → Style: robo, coucou (personal build only) or ambxst (core settings.rs `mascot`; lib/mascots.ts). */
export function isRobo(): boolean {
  return currentMascot() === "robo";
}

/** His ask: the wardrobe dresses the chat in front (any mascot); no chat, no wardrobe. */
export function hasWardrobe(): boolean {
  return Looks.frontConv() != null;
}

/** settings.rs RobotPrefs, with its defaults. */
export interface RobotPrefs {
  shape: RobotHeadShape; antenna: boolean; speed: number;
  customColors: boolean; shell: string; trim: string; screen: string;
}
export function prefs(): RobotPrefs {
  const p = (State.settings as { robot?: Partial<RobotPrefs> }).robot ?? {};
  return {
    shape: SHAPES.includes(p.shape as RobotHeadShape) ? (p.shape as RobotHeadShape) : "rectangle",
    antenna: p.antenna !== false,
    speed: [0.5, 1, 1.5, 2].includes(p.speed as number) ? (p.speed as number) : 1,
    customColors: !!p.customColors,
    shell: p.shell || "#2b49a3",
    trim: p.trim || "#93a6c8",
    screen: p.screen || "#e8f2ff",
  };
}

/** Tools that look things up rather than change them: upstream's step labels (hooks.ts TOOL_LABELS). */
const LOOKING = ["Searches", "Reads", "Lists", "Searches the web", "Fetches"];

/** True when task's newest step is a search or a read (Grep, Glob, Read…). */
function looking(task: { steps?: string[] } | null | undefined): boolean {
  const step = task?.steps?.[task.steps.length - 1];
  return !!step && LOOKING.some((l) => step === t(l) || step.startsWith(t(l) + " · "));
}

/**
 * What Robo shows for a Coucou state (the robot has its own nine faces).
 * Coucou has no "searching" of its own (every tool is "working"): Robo
 * searches while the task's current step is a search or a read.
 */
export function robotState(s: BotStateName, speaking = false, task?: { steps?: string[] } | null): RobotHeadState {
  if (speaking) return "speaking";
  switch (s) {
    case "working": return looking(task) ? "searching" : "working";
    case "thinking": return "thinking";
    case "searching": return "searching";
    case "approval":
    case "question": return "listening";
    case "finished": return "happy";
    case "error":
    case "ratelimit":
    case "dizzy": return "error";
    case "sleeping": return "sleeping";
    default: return "idle";
  }
}

/** The operator AI's colour: the pill in front (Claude's orange by default). */
export function brandColor(): string {
  return State.focusTask?.color || "#D97757";
}

/** The island's head: Settings' shape, antenna, speed; brand colours unless custom. */
export function mainLook(): RobotLook {
  // His ask: a chat in front wears its own head (lib/looks.ts).
  const conv = Looks.frontConv();
  if (conv) return Looks.roboLook(conv, brandColor());
  const p = prefs();
  const colors = p.customColors ? { shell: p.shell, trim: p.trim, screen: p.screen } : brandLook(brandColor());
  return { shape: p.shape, antenna: p.antenna, speed: p.speed, ...colors };
}

/**
 * A mini's head. His ask: a conversation of the user's is THEIR Robo (Settings'
 * shape, antenna, colours: custom ones, else its pill's brand colours);
 * helpers and integrations get a shape and antenna picked once by their id.
 */
export function miniHeadLook(id: string, color: string, userConversation = false): RobotLook {
  const p = prefs();
  if (userConversation) {
    const colors = p.customColors ? { shell: p.shell, trim: p.trim, screen: p.screen } : brandLook(color || "#D97757");
    return { shape: p.shape, antenna: p.antenna, speed: p.speed, ...colors };
  }
  return { ...miniLook(id), speed: p.speed, ...brandLook(color || "#D97757") };
}

/** A chat conversation's pill (chat.ts convPillId `agent_c-…`, tagged `conv`). */
export function isConversation(id: string, task?: { conv?: string } | null): boolean {
  return !!task?.conv || id.startsWith("agent_c-");
}
