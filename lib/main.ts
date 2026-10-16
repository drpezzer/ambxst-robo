// windows/src/main.ts without the page: boots the bridge, wires the island and
// every upstream handler (hooks, integrations, shortcuts, Spotify, recap), then
// starts the greeting. The QML host calls `start(host)` once.

import { Bridge, onEvent } from "@coucou/core/bridge";
import { Sound } from "@coucou/core/sound";
import { State, type Settings } from "@coucou/core/state";
import { registerHookHandlers } from "@coucou/island/hooks";
import { registerIntegrationHandlers, refreshConfigured } from "@coucou/island/integrations";
import { registerShortcutHandlers } from "@coucou/island/shortcuts";
import { applySpotify, registerSpotifyHandlers } from "@coucou/island/spotify";
import { SPOTIFY_ID } from "@coucou/core/spotify";
import { Recap } from "@coucou/recap/recap";
import { onLanguageChange, resolveLanguage, setLanguage, systemLanguages } from "@coucou/i18n/i18n";
import { Island, type IslandHost } from "./island";
import * as RoboCfg from "./robot/config";
import { PILL_CATALOG } from "@coucou/core/pills";
import { toOneLine } from "@coucou/core/diff";
import { quietLaunch } from "./views/desktop";
import { history } from "./views/history";
import { chat, convPillId, showChat } from "./views/chat";
import * as Finished from "./views/finished";
import * as Compaction from "./compaction";
import * as Remote from "./remote";

/**
 * Port (his call): the main pill upstream names "VS Code" is Claude Code here
 * (every terminal Claude Code session reports to it; there is no VS Code), in
 * Claude's colour — the mascot wears a focused integration's colour, so he does too.
 * Upstream's own Claude orange (Claude Desktop's pill).
 */
const CLAUDE_CODE_PILL = { name: "Claude Code", color: "#D97757" };

/** Port: helpers' pills, in shades of Claude's orange (one each, in turn). */
const HELPER_COLORS = ["#E8A87C", "#C9694A", "#F2C6A0", "#B5523A"];
let helperSeq = 0;
type AgentTaskLike = { id: string };
interface HelperHook {
  hook_event_name?: string;
  last_assistant_message?: string;
  coucou_agent?: string;
  coucou_helper?: { name?: string; type?: string };
  term_editor?: string;
  /** Port: the chat conversation this came from (ambxst-robo chat.rs Chats). */
  coucou_conv?: string;
}
for (const def of PILL_CATALOG) {
  if (def.id === "integration_claude") Object.assign(def as { name: string; color: string }, CLAUDE_CODE_PILL);
  // Port (his ask): the music pill is any media player's (lib/media.ts), not Spotify's.
  if (def.id === "integration_spotify") Object.assign(def as { name: string }, { name: "Media" });
}

function applyLanguage() {
  setLanguage(resolveLanguage(State.settings.language, systemLanguages()));
}

/** Pause has to reach Rust too, or the pollers keep calling out. */
function setPaused(on: boolean) {
  if (State.paused === on) return;
  State.paused = on;
  void Bridge.setPaused(on);
}

export let island: Island | null = null;

/** The tray menu's entries, which Ambxst offers from the bar's Robo instead. */
export function tray(what: string) {
  if (!island) return;
  switch (what) {
    case "settings":
      setPaused(false);
      island.alert("settings");
      break;
    case "open":
      setPaused(false);
      island.alert(State.defaultView());
      break;
    case "recap":
      setPaused(false);
      void Recap.open(island);
      break;
    case "wardrobe":
      if (!RoboCfg.hasWardrobe()) break; // the wardrobe is the Coucou mascot's
      setPaused(false);
      island.alert("wardrobe");
      break;
    case "pause":
      setPaused(!State.paused);
      if (State.paused) island.fsm.forceHidden();
      else island.reveal();
      break;
  }
}

export async function start(host: IslandHost, opts: { greet: boolean; greetLater?: boolean }) {
  void Sound.preload();

  const isl = new Island(host);
  island = isl;

  const boot = await Bridge.boot();
  if (boot) {
    State.settings = { ...State.settings, ...boot.settings };
  }
  // ambxst-robo outlives shell reloads: its pause must follow this island's.
  void Bridge.setPaused(State.paused);
  onLanguageChange(() => State.notify());
  applyLanguage();
  void Bridge.setSystemLanguages(systemLanguages());
  isl.applySettings();
  State.loadIntegrationTasks();
  chat();
  void history().restore();
  // Port (his ask): which chats have Claude Code's Remote Control on.
  void Remote.init();
  // Port (his ask): the default Claude Code bot only while no chat is going
  // (or while a terminal session works on it): a chat in front is that chat.
  hideIdleClaudeBesideChats();
  await isl.desktop.init();

  await onEvent<string>("tray", (what) => tray(what));
  await onEvent<null>("show-chat", () => showChat());
  // Port: a chat turn (Claude Code) is over. ambxst-robo sends its work as the
  // hooks a terminal session would, except Stop: the chat already played its
  // sound and shows the answer, so the pill only takes the last line and goes
  // back to idle as after Stop (5.2 s), without the "finished" alert.
  await onEvent<HelperHook>("hook", (p) => {
    // His ask: helpers (subagents) are silent: their first event says so,
    // the rest only carry their agent tag (its pill is a helper's). Upstream's
    // handler, next, plays nothing for them; the flag ends after it.
    if (p.coucou_agent && (p.coucou_helper
      || (State.tasks.find((x) => x.id === `agent_${p.coucou_agent}`) as { helperOf?: string } | undefined)?.helperOf)) {
      (Sound as unknown as { quiet: boolean }).quiet = true;
    }
    // Port (his ask): Claude Code compacting (lib/compaction.ts). A chat
    // conversation by its id, a terminal session by its session id; a
    // helper's own compaction is not shown.
    if ((p.hook_event_name === "PreCompact" || p.hook_event_name === "PostCompact") && !p.coucou_helper) {
      const sid = (p as { session_id?: string }).session_id ?? "";
      const key = p.coucou_conv || (sid ? `session:${sid}` : "");
      if (p.hook_event_name === "PreCompact") {
        Compaction.start(key, Number((p as { coucou_context_tokens?: number }).coucou_context_tokens) || 0);
      } else if (Compaction.finish(key) && p.coucou_conv && !(p as { coucou_compact_error?: string }).coucou_compact_error) {
        chat().noteCompacted(p.coucou_conv);
      }
      return;
    }
    // Port: a helper (subagent) of a Claude Code session, chat or terminal
    // (ambxst-robo tags its events with an agent `h-…`). Its pill is made here
    // first, named after its task in Claude's shades, so upstream's handler
    // (which runs next) finds it and gives it its steps, diffs and Stop.
    if (p.coucou_helper && p.coucou_agent) {
      const id = `agent_${p.coucou_agent}`;
      if (!State.tasks.some((x) => x.id === id)) {
        State.upsertExternalAgent(id, p.coucou_helper.name || "Helper", HELPER_COLORS[helperSeq++ % HELPER_COLORS.length]);
      }
      const helper = State.tasks.find((x) => x.id === id) as (AgentTaskLike & { helperOf?: string }) | undefined;
      if (helper) {
        helper.helperOf = p.coucou_conv ? convPillId(p.coucou_conv)
          : p.term_editor === "cursor" ? "agent_cursor" : "integration_claude";
      }
      return;
    }
    // Port: a conversation's own work goes to its pill (its mini), made here
    // first with its title so upstream's handler doesn't name it after its tag.
    if (p.coucou_conv) {
      chat().ensureConvPill(p.coucou_conv);
      // A message sent to its Remote Control session from the phone or
      // claude.ai: it joins the log, its answer will follow (terminalDone).
      if (p.hook_event_name === "UserPromptSubmit" && Remote.isOn(p.coucou_conv)) {
        chat().remotePrompt(p.coucou_conv, String((p as { prompt?: string }).prompt ?? ""));
      }
      if (p.hook_event_name === "ChatTurnDone") {
        // The turn is over: any compaction of it is too.
        if (Compaction.running(p.coucou_conv)) Compaction.finish(p.coucou_conv);
        chat().finishPill(p.coucou_conv, toOneLine(p.last_assistant_message ?? ""));
        // His ask: an answer that lands while the user isn't on its chat page
        // (the notch closed, another view or conversation) raises the finished
        // popup, as a terminal session's Stop does.
        const watching = State.mode === "expanded" && State.view === "prompt" && chat().conv === p.coucou_conv;
        const sid = (p as { session_id?: string }).session_id ?? "";
        if (!watching && sid && !State.pendingApproval) {
          Finished.noteStop(sid, p.last_assistant_message ?? "");
          Finished.noteConv(sid, p.coucou_conv);
          const pid = convPillId(p.coucou_conv);
          const pill = State.tasks.find((x) => x.id === pid) as { sessionId?: string | null } | undefined;
          if (pill) pill.sessionId = sid;
          State.setFocus(pid);
          Sound.play("finish");
          isl.alert("finished");
        }
        // A message typed into its terminal from the chat page: the answer.
        void chat().terminalDone(p.coucou_conv, p.last_assistant_message ?? "");
      }
      return;
    }
    // Port: the finished popup's stand-in for the whole answer (lib/views/finished.ts).
    if (p.hook_event_name === "Stop" && !p.coucou_agent) {
      const sid = (p as { session_id?: string }).session_id ?? "";
      Finished.noteStop(sid, p.last_assistant_message ?? "");
      // The card is about this session, whatever the pill heard before (after
      // a shell reload a Stop can be the first thing it hears).
      const pill = State.tasks.find((x) => x.id === (p.term_editor === "cursor" ? "agent_cursor" : "integration_claude"));
      if (pill && sid) (pill as { sessionId?: string | null }).sessionId = sid;
    }
    if (p.hook_event_name !== "ChatTurnDone") return;
    const id = "integration_claude";
    const task = State.tasks.find((x) => x.id === id);
    if (!task) return;
    State.updateTask(id, "finished");
    const line = toOneLine(p.last_assistant_message ?? "");
    if (line) {
      State.appendStep(id, line);
      task.finalLine = line;
    }
    window.setTimeout(() => {
      const t = State.tasks.find((x) => x.id === id);
      if (t && t.state === "finished") State.updateTask(id, "idle");
    }, 5200);
    State.notify();
  });

  await onEvent<null>("sounds-changed", () => {
    void Sound.reload().then(() => Sound.play("pop"));
  });

  await onEvent<Settings>("settings-changed", (s) => {
    const previousMain = State.mainPillId;
    State.settings = { ...State.settings, ...s };
    applyLanguage();
    isl.applySettings();
    State.loadIntegrationTasks();
    if (State.mainPillId !== previousMain) State.setFocus(State.mainPillId);
    void refreshConfigured();
  });

  registerHookHandlers(isl);
  // After upstream's hook handler: a helper's quiet ends with its event.
  await onEvent<unknown>("hook", () => { (Sound as unknown as { quiet: boolean }).quiet = false; });
  registerIntegrationHandlers(isl);
  registerShortcutHandlers(isl, () => setPaused(false));
  registerSpotifyHandlers(isl);
  if (State.settings.activeIntegrations.includes(SPOTIFY_ID)) {
    // Port: the shell reports the player (lib/media.ts); ambxst-robo's
    // Spotify-only answer is not shown (it would cover the shell's).
    void Bridge.spotifyRefresh();
  }

  const checkRecap = () => void Recap.check(isl);
  isl.onGreetingDone = checkRecap;
  isl.onWake = checkRecap;
  await onEvent<null>("recap-check", checkRecap);

  // Upstream greets on every launch. Ambxst reloads the shell often, so the
  // host decides (first start of the session only).
  if (opts.greet) isl.launch();
  else {
    isl.fsm.forcePetit();
    // Upstream's greeting ends with desktop.launch() (back to his desktop
    // spot); without a greeting it has to happen here, or a mascot left on the
    // desktop stays hidden from the island and absent from the desktop.
    // The host greets a moment later (first start of the session): the
    // greeting's end flies him out, as upstream. Otherwise this is a shell
    // reload: he simply reappears at his spot (no fly-out).
    if (!opts.greetLater) {
      quietLaunch();
      isl.desktop.launch();
    }
  }
  return isl;
}

/** The default Claude Code pill, idle while chats (conversation pills) are up. */
function claudeAside(t: { id: string; state: string } | null | undefined): boolean {
  if (!t || t.id !== "integration_claude") return false;
  if (t.state !== "idle" && t.state !== "sleeping") return false;
  return State.tasks.some((x) => x.id.startsWith("agent_c-"));
}

function hideIdleClaudeBesideChats() {
  const S = State as unknown as { tasks: AgentTaskLike[]; focusId: string | null };
  Object.defineProperty(State, "otherTasks", {
    configurable: true,
    get: () => {
      const front = (State as unknown as { focusTask: { id: string } | null }).focusTask?.id;
      return S.tasks.filter((t) => t.id !== front && !claudeAside(t as never));
    },
  });
  Object.defineProperty(State, "focusTask", {
    configurable: true,
    get: () => {
      const f = S.tasks.find((t) => t.id === S.focusId) ?? S.tasks[0] ?? null;
      if (!claudeAside(f as never)) return f;
      // The chat on the page, else the first chat.
      const conv = chat().conv;
      return S.tasks.find((t) => t.id === `agent_${conv}`) ?? S.tasks.find((t) => t.id.startsWith("agent_c-")) ?? f;
    },
  });
}
