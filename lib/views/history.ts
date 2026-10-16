// Port only (no upstream equivalent): the Robo tab's chats column. Earlier
// chats, most recently used first — Claude Code sessions from every project
// and chats started in Robo — listed by ambxst-robo (history.rs, cached on
// file mtimes), and reopened in the chat (lib/views/chat.ts's one chat) to be
// continued. HistoryColumn.qml draws it.

import { invoke } from "@tauri-apps/api/core";
import { Bridge } from "@coucou/core/bridge";
import { providerDef, withModel, type ProviderId } from "@coucou/core/providers";
import { Sound } from "@coucou/core/sound";
import { State } from "@coucou/core/state";
import { N_, t } from "@coucou/i18n/i18n";
import { island } from "../main";
import { CLAUDE_CODE, CLAUDE_CODE_ID, modelLabel } from "../claudecode";
import { chat, rowsOf, type CoreChat, type CoreConv } from "./chat";

const STRINGS = {
  title: N_("Chats"),
  claudeCode: N_("Claude Code"),
  empty: N_("No chats yet"),
  busy: N_("Wait for the answer to finish first."),
};

export function strings() {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(STRINGS)) out[k] = t(v);
  return out;
}

/** history.rs Item. */
interface Item {
  kind: "claude" | "coucou";
  id: string;
  title: string;
  project: string;
  provider: string;
  model: string;
  updated: number;
}

/** What a card shows. */
export interface Card {
  kind: string;
  id: string;
  /** Top-left: "Claude Code", or "Robo · <model>". */
  top: string;
  /** Top-right: the project folder (Claude Code sessions only). */
  corner: string;
  title: string;
  accent: string;
  current: boolean;
}

/** "claude-sonnet-4-5-20250929" → "Claude Sonnet 4.5". */
function prettyClaude(id: string): string {
  const m = /^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/.exec(id);
  if (!m) return id;
  const family = m[1].charAt(0).toUpperCase() + m[1].slice(1);
  return `Claude ${family} ${m[2]}${m[3] ? "." + m[3] : ""}`;
}

/** The provider / model half of a Robo chat's label. */
export function modelName(provider: string, model: string): string {
  if (provider === CLAUDE_CODE_ID) return model ? modelLabel(model) : t(STRINGS.claudeCode);
  if (provider === "anthropic") return model ? prettyClaude(model) : "Anthropic";
  const name = t(providerDef(provider).name);
  return model ? `${name} ${model}` : name;
}

function card(item: Item, current: { kind: string; id: string } | null): Card {
  const isCurrent = !!current && current.kind === item.kind && current.id === item.id;
  if (item.kind === "claude") {
    return {
      kind: item.kind, id: item.id, top: t(STRINGS.claudeCode), corner: item.project, title: item.title,
      accent: CLAUDE_CODE.accent, current: isCurrent,
    };
  }
  return {
    kind: item.kind, id: item.id, top: `Robo · ${modelName(item.provider, item.model)}`, corner: "",
    title: item.title, accent: providerDef(item.provider).accent, current: isCurrent,
  };
}

export interface HistoryHooks {
  changed(): void;
}

class History {
  cards: Card[] = [];
  /** A list came back at least once. */
  loaded = false;
  /** The card being opened, "kind:id". */
  opening = "";
  /** A short line under the title when opening failed. */
  error = "";
  private hooks: HistoryHooks[] = [];
  private inFlight = false;
  private again = false;

  addHooks(h: HistoryHooks) { if (!this.hooks.includes(h)) this.hooks.push(h); }
  removeHooks(h: HistoryHooks) { this.hooks = this.hooks.filter((x) => x !== h); }
  private changed() { for (const h of this.hooks.slice()) h.changed(); }

  /** Asks ambxst-robo for the list (cheap: unchanged files are not read again). */
  async refresh() {
    if (this.inFlight) {
      this.again = true;
      return;
    }
    this.inFlight = true;
    try {
      const r = await invoke<{ items: Item[]; current: { kind: string; id: string } | null }>("chat_history_list");
      if (r && Array.isArray(r.items)) {
        const cards = r.items.map((i) => card(i, r.current));
        // Port (performance): the same list again (most refreshes) redraws
        // nothing: a new list rebuilt every card of the column.
        if (!this.loaded || JSON.stringify(cards) !== JSON.stringify(this.cards)) {
          this.cards = cards;
          this.loaded = true;
          this.changed();
        }
      }
    } catch {
      // No ambxst-robo: the column stays as it was.
    } finally {
      this.inFlight = false;
      if (this.again) {
        this.again = false;
        void this.refresh();
      }
    }
  }

  /**
   * Port: ambxst-robo outlives shell reloads, and its conversations with it: a
   * freshly started island shows the current one again (instead of an empty
   * chat that the next message would silently continue), and the others come
   * back as their minis, still answering if they were.
   */
  async restore(): Promise<void> {
    if (State.chatHistory.length > 0) return;
    try {
      const r = await invoke<CoreChat & { convs?: CoreConv[] }>("chat_current", {});
      if (State.chatHistory.length > 0) return;
      if (r.conv) chat().restore(r);
      else if (r.turns?.length || r.pending) {
        // An older core: one conversation, shown as it is.
        State.chatHistory = rowsOf(r);
        chat().reloaded();
      }
      State.notify();
      this.changed();
    } catch {
      // An older core without chat_current: the chat starts empty, as before.
    }
  }

  /**
   * Port (his ask): removes a card (right-click twice in the column). Its file
   * goes to Coucou's trash folder; the chat starts afresh if it was open.
   */
  async remove(kind: string, id: string): Promise<boolean> {
    try {
      const r = await invoke<{ wasOpen: boolean; conv?: string | null; current?: string }>("chat_delete", { kind, id });
      this.cards = this.cards.filter((c) => !(c.kind === kind && c.id === id));
      // Port: the open conversation that was this chat closes, mini and all.
      if (r.conv) chat().forget(r.conv);
      if (r.wasOpen) {
        State.chatHistory = [];
        if (r.current) chat().adopt(r.current, { turns: [] }, { applyModel: false });
        else chat().reloaded();
      }
      State.notify();
      this.error = "";
      this.changed();
      void this.refresh();
      return true;
    } catch (err) {
      this.error = String(err).replace(/^Error:\s*/, "");
      this.changed();
      return false;
    }
  }

  /** Opens a card in the chat: its turns come back and the next message continues it. */
  async open(kind: string, id: string): Promise<boolean> {
    const c = chat();
    // Port (multitasking): an answer on its way carries on in its own
    // conversation (its mini) while another chat is opened.
    if (this.opening) return false;
    this.opening = `${kind}:${id}`;
    this.error = "";
    this.changed();
    try {
      const r = await invoke<CoreChat & { title?: string }>("chat_open", { kind, id });
      if (r.conv) {
        // ambxst-robo reuses a conversation nobody talked in: what this island
        // showed of it is another chat's.
        if (r.conv === c.conv) c.markStale(r.conv);
        // The chat answers with the provider (and model) this chat had.
        c.adopt(r.conv, { ...r, current: { kind, id } });
      } else {
        // An older core: the one conversation is replaced.
        if (c.pickerOpen) c.closePicker();
        State.chatHistory = rowsOf(r);
        State.droppedFile = null;
        State.promptContext = null;
        State.stateOverride = null;
        c.reloaded();
      }
      Sound.play("pop");
      // From a card or a page, the chat comes into view (a card waiting for a
      // click stays).
      const v = State.view;
      if (island && v !== "overview" && v !== "empty" && v !== "prompt" && !State.pendingApproval) {
        island.setView(State.defaultView());
      }
      State.notify();
      this.opening = "";
      this.changed();
      void this.refresh();
      return true;
    } catch (err) {
      this.opening = "";
      this.error = String(err).replace(/^Error:\s*/, "");
      this.changed();
      void this.refresh();
      return false;
    }
  }
}


let instance: History | null = null;

export function history(): History {
  instance ??= new History();
  return instance;
}
