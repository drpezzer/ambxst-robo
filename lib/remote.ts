// Port only (his ask): Claude Code's Remote Control for a chat (ambxst-robo
// remote.rs). While it is on, the chat's messages are typed into the
// interactive session it runs (chat.ts send), the phone or claude.ai/code
// drives the same session, and its answers come back as the conversation's
// hooks. Which chats have it on, and their session URL.

import { invoke } from "@tauri-apps/api/core";
import { onEvent } from "@coucou/core/bridge";
import { State } from "@coucou/core/state";

export interface RemoteState { conv: string; on: boolean; url?: string | null; sessionId?: string }

const on = new Map<string, RemoteState>();
/** Chats whose Remote Control is starting (the button spins). */
const starting = new Set<string>();
let listeners: Array<() => void> = [];

function changed() {
  for (let i = 0; i < listeners.length; i++) listeners[i]();
  State.notify();
}

export function onChange(fn: () => void) {
  listeners.push(fn);
}

export function isOn(conv: string): boolean {
  return on.has(conv);
}
export function isStarting(conv: string): boolean {
  return starting.has(conv) || queued.has(conv);
}

/** Port (his ask): asked for while the chat answers: it comes on after (chat.ts). */
const queued = new Set<string>();
export function isQueued(conv: string): boolean {
  return queued.has(conv);
}
export function setQueued(conv: string, on: boolean) {
  if (on) queued.add(conv);
  else queued.delete(conv);
  changed();
}
export function stateOf(conv: string): RemoteState | null {
  return on.get(conv) ?? null;
}

function apply(s: RemoteState) {
  if (s.on) on.set(s.conv, s);
  else on.delete(s.conv);
}

export async function init() {
  try {
    const list = await invoke<RemoteState[]>("remote_list", {});
    for (let i = 0; i < list.length; i++) apply(list[i]);
  } catch { /* an older ambxst-robo: none */ }
  await onEvent<RemoteState>("remote-changed", (s) => {
    apply(s);
    changed();
  });
  changed();
}

/** Turns it on: the state (with its URL), or throws what stopped it. */
export async function start(conv: string): Promise<RemoteState> {
  starting.add(conv);
  changed();
  try {
    const s = await invoke<RemoteState>("remote_start", { conv });
    apply(s);
    return s;
  } finally {
    starting.delete(conv);
    changed();
  }
}

export async function stop(conv: string) {
  on.delete(conv);
  changed();
  try {
    await invoke<boolean>("remote_stop", { conv });
  } catch { /* gone already */ }
}

export async function send(conv: string, text: string) {
  await invoke<boolean>("remote_send", { conv, text });
}

const qrCache = new Map<string, string[]>();
/** The QR rows ("1" dark) of `text`, from ambxst-robo (cached), to `done`. */
export function qr(text: string, done: (rows: string[]) => void) {
  const hit = qrCache.get(text);
  if (hit) {
    done(hit);
    return;
  }
  void invoke<string[]>("remote_qr", { text }).then((rows) => {
    qrCache.set(text, rows);
    done(rows);
  }).catch(() => done([]));
}
