// Port only (his ask): the compact "finished" popup (FinishedView.qml) grows
// over hover to show Claude's whole last answer, and takes a reply typed
// right there. The answer comes from the session's transcript (ambxst-robo
// session_reply.rs; the hook's copy is capped), the reply is typed into the
// session's own kitty window, as if typed there.

import { invoke } from "@tauri-apps/api/core";
import { Sound } from "@coucou/core/sound";
import { State } from "@coucou/core/state";
import { N_, t } from "@coucou/i18n/i18n";
import { chat } from "./chat";

const STRINGS = {
  reply: N_("Reply"),
  placeholder: N_("Reply to Claude…"),
  send: N_("Send"),
};

export function strings() {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(STRINGS)) out[k] = t(v);
  return out;
}

/** The session a finished card is about (its pill's last session). */
export function sessionOf(task: { sessionId?: string | null } | null): string {
  return task?.sessionId ?? "";
}

/**
 * The Stop hooks' own copy of each session's last answer (main.ts): capped at
 * 2 000 characters by the relay, it stands in until the transcript has it.
 */
const hookText = new Map<string, string>();
export function noteStop(sessionId: string, text: string) {
  if (sessionId && text) hookText.set(sessionId, text);
}
/** Port (his ask): the chat conversation a session is (its turns end without a Stop hook). */
const convText = new Map<string, string>();
export function noteConv(sessionId: string, conv: string) {
  if (sessionId && conv) convText.set(sessionId, conv);
}
export function convOf(sessionId: string): string {
  return convText.get(sessionId) ?? "";
}
export function hookReply(sessionId: string): string {
  return hookText.get(sessionId) ?? "";
}

const wait = (ms: number) => new Promise<void>((r) => window.setTimeout(r, ms));

/**
 * The whole last answer of `sessionId`, "" when it can't be read. The Stop
 * hook fires before Claude Code has written that answer to the transcript, so
 * an early read finds the turn still open: it is read again for a moment.
 */
export async function lastReply(sessionId: string): Promise<string> {
  if (!sessionId) return "";
  // (An index, not for…of: Qt 6.12's incremental GC can free the loop's
  // iterator while the function waits at an await inside it, and the resume
  // then segfaults the shell. QV4_GC_TIMELIMIT=0 is set for the shell too.)
  const delays = [0, 300, 700, 1200, 2000];
  for (let i = 0; i < delays.length; i++) {
    const delay = delays[i];
    if (delay) await wait(delay);
    try {
      const text = (await invoke<string | null>("session_last_reply", { sessionId })) ?? "";
      if (text) return text;
    } catch {
      return "";
    }
  }
  return "";
}

/** Types `text` into the session's terminal. Resolves to an error message, or "" once sent. */
export async function reply(sessionId: string, text: string): Promise<string> {
  const msg = text.trim();
  if (!msg) return "";
  if (!sessionId) return t("This session can't be reached from here.");
  // A chat conversation is answered through the chat, not a terminal.
  const conv = convText.get(sessionId);
  if (conv) {
    if (!chat().replyTo(conv, msg)) return t("This session can't be reached from here.");
    State.notify();
    return "";
  }
  try {
    await invoke<boolean>("session_reply", { sessionId, text: msg });
    Sound.play("send");
    State.notify();
    return "";
  } catch (err) {
    Sound.play("error");
    return String(err).replace(/^Error:\s*/, "");
  }
}
