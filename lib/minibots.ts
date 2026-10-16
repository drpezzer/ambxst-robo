// mascot/minibots.ts without canvases: each QML MiniBot owns one of these and
// draws its engine; the island's frame loop ticks every live one, as upstream.

import { BotEngine, hexToRGB } from "@coucou/mascot/engine";
import { Robot, hashSeed } from "./robot/mascot";
import * as Robo from "./robot/config";
import { State, type AgentTask } from "@coucou/core/state";
import * as Blobs from "./blob";
import * as Looks from "./looks";

/** Port (his ask): a chat's mini wears that chat's colour (lib/looks.ts). */
function bodyOf(task: AgentTask): ReturnType<typeof hexToRGB> {
  const conv = Looks.convOfTask(task as AgentTask & { conv?: string });
  return hexToRGB(conv ? Looks.bodyHex(conv, task.color) : task.color);
}

export interface MiniBot {
  engine: BotEngine;
  cssSize: number;
  taskId: string;
  dancing?: () => boolean;
  /** QML repaint hook. */
  paint?: () => void;
  /** Port: busy at the last tick (undefined until the first one). */
  wasBusy?: boolean;
  /**
   * Port (performance): bumped whenever a tick would repaint it (with paint()).
   * The bar repaints its minis from this on its own tick, all with its Robo.
   */
  version: number;
  /** Port: the key it is shared under (the bars' minis), and how many hold it. */
  shareKey?: string;
  refs?: number;
  /** Port (his ask): Robo instead of the Coucou mascot while Settings choose him. */
  robot?: Robot | null;
  /** Port: always the mascot (Settings' mascot card for him). */
  coucouOnly?: boolean;
  task?: AgentTask;
  /** Port (his ask): a helper (subagent) is a liquid blob, not a mascot (lib/blob.ts). */
  blob?: Blobs.Blob | null;
}

/** Port: the mini's Robo (made when Settings switch to him, dropped when back). */
function robotOf(mb: MiniBot): Robot | null {
  if (!Robo.isRobo() || mb.coucouOnly) {
    mb.robot = null;
    return null;
  }
  const t = mb.task;
  // (Checked every tick: a pill is tagged a conversation just after its mini is made.)
  const liveTask = (State.tasks.find((x) => x.id === mb.taskId) ?? t) as (AgentTask & { conv?: string }) | undefined;
  const conv = Looks.convOfTask(liveTask ?? { id: mb.taskId });
  const look = conv ? Looks.roboLook(conv, t ? t.color : "") : Robo.miniHeadLook(mb.taskId, t ? t.color : "", Robo.isConversation(mb.taskId, liveTask));
  if (!mb.robot) {
    mb.robot = new Robot(look, mb.cssSize * 0.6, hashSeed(mb.taskId));
    mb.robot.sim.mini = true;
  }
  else mb.robot.setLook(look);
  if (t) mb.robot.setState(Robo.robotState(t.state as never, false, t));
  return mb.robot;
}

/**
 * Port: the mini's liquid blob if its task is a helper. Decided live, not only
 * when the mini is made: a helper's pill is announced (State notifies, the
 * bar's grid builds its mini at once) before main.ts tags it `helperOf`, so a
 * mini made then would stay a mascot (Robo or the Coucou mascot) for good.
 */
function blobOf(mb: MiniBot): Blobs.Blob | null {
  if (mb.blob) return mb.blob;
  const task = (State.tasks.find((x) => x.id === mb.taskId) ?? mb.task) as AgentTask | undefined;
  if (!Blobs.isHelper(task)) return null;
  mb.blob = Blobs.createBlob(task as AgentTask, hashSeed(mb.taskId) * Math.PI * 2);
  mb.robot = null;
  return mb.blob;
}

const live = new Set<MiniBot>();
/** Port (performance): the bars' minis, one per pill for every screen's bar. */
const shared = new Map<string, MiniBot>();

/** Repaint it (its version for the bar, its own hook otherwise). */
function touch(mb: MiniBot) {
  mb.version++;
  mb.paint?.();
}

/**
 * Port (performance): a mini the bars share: one engine stepped per pill,
 * not one per screen. Drawn by whoever holds it; released like any other.
 */
export function shareMiniBot(task: AgentTask, bodySize: number): MiniBot {
  const key = task.id + "@" + bodySize;
  const had = shared.get(key);
  if (had && live.has(had)) {
    had.refs = (had.refs ?? 1) + 1;
    return had;
  }
  const mb = createMiniBot(task, bodySize);
  mb.shareKey = key;
  mb.refs = 1;
  shared.set(key, mb);
  return mb;
}

/** A mini mascot whose body is `bodySize` px across; its canvas is bodySize / 0.6. */
export function createMiniBot(task: AgentTask, bodySize: number, dancing?: () => boolean): MiniBot {
  const engine = new BotEngine();
  engine.isMini = true;
  engine.bodyColor = bodyOf(task);
  engine.setState(task.state, true);
  if (task.emote) engine.setPermanentEmote(task.emote);
  if (task.miniEye) {
    engine.permanentEye = task.miniEye;
    engine.eyeOverride = task.miniEye;
    engine.eyeOverrideUntil = Number.POSITIVE_INFINITY;
  }
  const mb: MiniBot = { engine, cssSize: bodySize / 0.6, taskId: task.id, dancing, task, version: 0 };
  blobOf(mb);
  live.add(mb);
  return mb;
}

/** Port: helpers' badge colour (their parent, Claude Code). */
export const HELPER_BADGE = "#D97757";

export function releaseMiniBot(mb: MiniBot) {
  if (mb.shareKey) {
    mb.refs = (mb.refs ?? 1) - 1;
    if (mb.refs > 0) return;
    if (shared.get(mb.shareKey) === mb) shared.delete(mb.shareKey);
  }
  live.delete(mb);
}

export function syncMiniBotStates(tasks: AgentTask[]) {
  for (const mb of live) {
    const task = tasks.find((t) => t.id === mb.taskId);
    if (!task) continue;
    mb.engine.setState(task.state);
    mb.engine.bodyColor = bodyOf(task);
    mb.task = task;
  }
}

export function tickMiniBots(dt: number) {
  for (const mb of live) {
    if (blobOf(mb)) {
      const task = (State.tasks.find((x) => x.id === mb.taskId) ?? mb.task) as AgentTask | undefined;
      if (task && Blobs.updateBlob(mb.blob!, task, dt)) touch(mb);
      continue;
    }
    mb.engine.setDancing(mb.dancing?.() ?? false);
    mb.engine.update(dt);
    // Port: Robo moves all the time (blinks, glances): always repainted.
    const robot = robotOf(mb);
    if (robot) {
      robot.update(dt);
      touch(mb);
      mb.wasBusy = true;
      continue;
    }
    // Port (performance): a still mini is not repainted (one last frame after
    // it settles); MiniBot also caps a moving one at ~24 repaints a second.
    const busy = mb.engine.busy;
    if (busy || mb.wasBusy !== false) touch(mb);
    mb.wasBusy = busy;
  }
}

/** Draws one mini into a CtxWrap the size of its canvas (already cleared). */
export function drawMiniBot(mb: MiniBot, ctx: CanvasRenderingContext2D) {
  const blob = blobOf(mb);
  if (blob) {
    Blobs.drawBlob(blob, ctx, mb.cssSize, mb.cssSize * 0.6);
    return;
  }
  const robot = robotOf(mb);
  if (robot) {
    // His head where the mascot's body sits: the canvas's middle (engine.draw's
    // body centre, 0.018 of the size below it), whatever his shape or antenna.
    const body = mb.cssSize * 0.6;
    robot.setBox(body);
    robot.drawAt(ctx, (mb.cssSize - body) / 2, (mb.cssSize - body) / 2 + mb.cssSize * 0.018);
    return;
  }
  ctx.save();
  mb.engine.applyDance(ctx, mb.cssSize, mb.cssSize);
  mb.engine.draw(ctx, mb.cssSize, mb.cssSize);
  ctx.restore();
}

export const miniBotCount = () => live.size;

/** The engine fields miniActive() reads: the same in upstream's engine and lib/public/engine.ts. */
interface EngineLike {
  tweens: Map<unknown, unknown>;
  particles: unknown[];
  cfg: Record<string, unknown>;
  permanentEmote: string | null;
  isDancing: boolean; dancingLevel: number;
  tilt: number; tgTilt: number; es: number; tgEs: number;
  slotH: number; slotHVel: number;
  col: number[]; colT: number[];
  eyeOverride: unknown; eyeOverrideUntil: number;
}

/**
 * Port (performance): a mini actually animating: a tween (a blink, a hop, a
 * state's entry), particles, a state that moves (working's hops, thinking's
 * scan, sleeping's breath), an emote's act, dancing, a colour or slot on its
 * way. Not its idle glances and breathing: those go on while the loop runs
 * for anything else, but an idle mini alone no longer keeps it running.
 * (engine.busy counts every mini busy for good: isMini.)
 */
function engineActive(e: EngineLike): boolean {
  const c = e.cfg;
  return e.tweens.size > 0 || e.particles.length > 0 ||
    // (upstream's names, then lib/public/engine.ts's)
    !!(c.bounces || c.hops || c.scans || c.breathes || c.zz || c.snores || c.sweat || c.sweats) ||
    !!e.permanentEmote || e.isDancing || e.dancingLevel > 0.001 ||
    Math.abs(e.tgTilt - e.tilt) > 0.002 || Math.abs(e.tgEs - e.es) > 0.002 ||
    e.slotH > 0.001 || Math.abs(e.slotHVel) > 0.001 ||
    Math.abs(e.col[0] - e.colT[0]) > 0.003 || Math.abs(e.col[1] - e.colT[1]) > 0.003 ||
    Math.abs(e.col[2] - e.colT[2]) > 0.003 ||
    (!!e.eyeOverride && isFinite(e.eyeOverrideUntil)) ||
    // Drawn from the clock: a working / thinking badge's dots, a dizzy, loving
    // or starry eye (a permanent one included).
    (c.badge as { kind?: string } | null)?.kind === "dots" ||
    TIMED_EYES.has(String(e.eyeOverride ?? c.eye));
}
const TIMED_EYES = new Set(["spiral", "heart", "star"]);

/** Port: a Robo mini moves on its own in any state but idle and asleep (and mid-jump or crossfade). */
function robotActive(r: Robot): boolean {
  const s = r.sim as unknown as { state: string; switched: number; jump?: unknown; blinkAge: number };
  return (s.state !== "idle" && s.state !== "sleeping") || s.switched < 1 || !!s.jump || s.blinkAge >= 0;
}

/** Port: a mini mid-animation (a helper's "finished" one, say) keeps the loop on. */
export function miniBotsBusy(): boolean {
  for (const mb of live) {
    if (mb.blob ? !mb.blob.popped : mb.robot ? robotActive(mb.robot) : engineActive(mb.engine as unknown as EngineLike)) return true;
  }
  return false;
}
