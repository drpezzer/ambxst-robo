// views/chat.ts buildPrompt / buildPicker without the DOM: the chat's send
// flow, the streamed answer (`chat-delta`) and the model picker's decisions,
// for mod/.../views/PromptView.qml to draw. One instance for the app, as
// upstream builds the prompt view once: the QML view is only loaded while it
// is on screen, the conversation in flight must outlive it.
//
// Markdown is parsed by upstream's own parser (views/markdown.ts); the QML
// side renders the blocks.

import { invoke } from "@tauri-apps/api/core";
import { Bridge, onEvent, type ChatContext, type ModelInfo } from "@coucou/core/bridge";
import {
  activeModel, pickModel, providerDef, visibleProviders, withModel, type ProviderDef,
} from "@coucou/core/providers";
import { Sound } from "@coucou/core/sound";
import { toOneLine } from "@coucou/core/diff";
import * as Compaction from "../compaction";
import * as Looks from "../looks";
import * as Remote from "../remote";
import { State, type AskedQuestion } from "@coucou/core/state";
import type { IslandViewName } from "@coucou/core/layout";
import { N_, t } from "@coucou/i18n/i18n";
import { island } from "../main";
import {
  CHAT_MODES, CHAT_PILL_ID, CHAT_PILL_NAME, CLAUDE_CODE, CLAUDE_CODE_ID, MODES_TITLE, SUBSCRIPTION_NOTE, chatMode, ensureDefaultProvider,
  migrateModel, modelLabel, setChatMode, type ChatModeId,
} from "../claudecode";

export { parseMarkdown, parseInline, safeWebUrl } from "@coucou/views/markdown";

const STRINGS = {
  placeholderFirst: N_("Ask me anything…"),
  placeholderNext: N_("Continue…"),
  send: N_("Send"),
  switchModel: N_("Switch provider or model"),
  noModel: N_("Choose a model"),
  loading: N_("Loading models…"),
  noKey: N_("No API key — add it in Settings."),
  openSettings: N_("Open Settings"),
  copy: N_("Copy"),
  copied: N_("Copied"),
  // Port (his ask): the working directory (the folder chip, a dropped folder).
  workDir: N_("Working directory"),
  workDirDefault: N_("Default"),
  useAsWorkDir: N_("Use as working directory"),
  tooBigWorkDir: N_("Folder too large to attach, so it's set as the working directory. Zip it if you want to attach its contents instead."),
};

/** ambxst-robo's refusal of a folder too big to copy (core/src/files.rs ingest_folder): the same key. */
const FOLDER_TOO_BIG = "That folder is too big to drop (over 2,000 files or 200 MB).";

/** The (translated) strings the QML view shows. */
export function strings() {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(STRINGS)) out[k] = t(v);
  return out;
}

let nextId = 1;

/** What the QML view hands in while it is loaded: redraw, focus the field. */
export interface ChatHooks {
  changed(): void;
  focusInput(): void;
}

export interface PickerChip { id: string; name: string; accent: string; on: boolean }
export interface PickerRow { id: string; label: string; on: boolean }
export interface PickerModeRow extends PickerRow { hint: string }

/**
 * Port (his ask): the chat's working directory as ambxst-robo reports it
 * (chat_work_dir / chat_set_work_dir / chat_pick_work_dir): the folder the
 * conversation's Claude Code turns run in.
 */
export interface WorkDirInfo {
  path: string;
  /** The folder's name; "" for Robo's own (the default). */
  name: string;
  isDefault: boolean;
  missing: boolean;
  /** Set: its Claude Code session can't follow (a new one starts there). */
  moved?: boolean;
  /** Pick: false when the chooser was cancelled. */
  picked?: boolean;
}

/** Port (his ask): the folder chip by the model button. */
export interface WorkDirChip {
  show: boolean;
  label: string;
  tooltip: string;
  /** The folder's full path (middle-click copies it). */
  path: string;
  isDefault: boolean;
  disabled: boolean;
}

/** The longest working-directory label the chip shows (characters), elided in the middle past it. */
const WORK_DIR_LABEL_MAX = 24;

/** Middle-elides `s` to `max` characters ("abc…xyz"). */
function elideMiddle(s: string, max: number): string {
  if (s.length <= max) return s;
  const keep = max - 1;
  const head = Math.ceil(keep / 2);
  return s.slice(0, head) + "…" + s.slice(s.length - (keep - head));
}

/**
 * Port (his ask): a working directory as the chip shows it: `~` for the home
 * folder, `~/sub/path` under it (`~/first/…/last` when long, the last folder
 * itself middle-elided if need be), the folder's own name elsewhere.
 */
export function workDirLabel(path: string, home: string, name = ""): string {
  const h = home.replace(/\/+$/, "");
  const p = path.replace(/\/+$/, "") || "/";
  if (h && p === h) return "~";
  if (!h || !p.startsWith(h + "/")) {
    const own = name || p.split("/").filter(Boolean).pop() || p;
    return elideMiddle(own, WORK_DIR_LABEL_MAX);
  }
  const segs = p.slice(h.length + 1).split("/").filter(Boolean);
  const full = "~/" + segs.join("/");
  if (full.length <= WORK_DIR_LABEL_MAX) return full;
  const last = segs[segs.length - 1];
  if (segs.length > 2) {
    const firstLast = `~/${segs[0]}/…/${last}`;
    if (firstLast.length <= WORK_DIR_LABEL_MAX) return firstLast;
  }
  const prefix = segs.length > 1 ? "~/…/" : "~/";
  return prefix + elideMiddle(last, WORK_DIR_LABEL_MAX - prefix.length);
}

/** A permission request or question from the chat's own Claude Code run (ambxst-robo pipe::ask_island). */
interface ChatPermission {
  /** Port: the conversation whose turn asks (chat.rs Chats). */
  coucou_conv?: string;
  request_id?: string;
  session_id?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
}


/**
 * Port (his ask): the little line over a message typed while Claude Code
 * works, at its bubble's top-left until Claude Code takes it in. One is
 * picked at random per message, never the same twice in a row.
 */
const WAIT_CAPTIONS = [
  N_("waiting politely…"),
  N_("no rush, I'll wait…"),
  N_("holding that thought…"),
  N_("didn't want to interrupt…"),
  N_("next in line…"),
  N_("saving this for a sec…"),
  N_("patiently queued…"),
  N_("waiting for a gap…"),
  N_("I'll slip it in soon…"),
  N_("tiptoeing in…"),
  N_("after this bit…"),
  N_("noted, coming up…"),
];
let lastCaption = -1;

/** A message typed while a turn runs, until it joins the log. */
interface Queued {
  id: number;
  content: string;
  /** Its WAIT_CAPTIONS line (English: translated as it is shown). */
  caption: string;
  /** Claude Code's running turn has it (chat_inject took it); else it goes as the next turn. */
  inCore: boolean;
}

function queuedOf(content: string, inCore: boolean): Queued {
  let i = Math.floor(Math.random() * WAIT_CAPTIONS.length);
  if (i === lastCaption) i = (i + 1 + Math.floor(Math.random() * (WAIT_CAPTIONS.length - 1))) % WAIT_CAPTIONS.length;
  lastCaption = i;
  return { id: nextId++, content, caption: WAIT_CAPTIONS[i], inCore };
}

/** What is left in a queue, as the one message that goes next. */
function joinedQueue(queued: Queued[]): string {
  return queued.map((q) => q.content).join("\n\n");
}

/** island/hooks.ts APPROVAL_FIELDS / approvalTarget(): what the card's code line shows. */
/** An unanswered chat card goes after this long (ambxst-robo gives up at 30 min, pipe.rs CHAT_DECISION_TIMEOUT; his bug: 110 s took it away mid-answer). */
const CHAT_CARD_TIMEOUT_MS = 30 * 60_000 + 5_000;

const APPROVAL_FIELDS =["command", "file_path", "path", "url", "query", "pattern", "prompt"];
function approvalTarget(tool: string, input: Record<string, unknown>): string {
  for (const field of APPROVAL_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) return `${tool} · ${value.trim()}`;
  }
  return tool;
}

/** island/hooks.ts askedQuestions(): the questions, if the card can show them all as options. */
function askedQuestions(tool: string, input: Record<string, unknown>): AskedQuestion[] | null {
  if (tool !== "AskUserQuestion" || !Array.isArray(input.questions)) return null;
  const out: AskedQuestion[] = [];
  for (const raw of input.questions as Record<string, unknown>[]) {
    const question = typeof raw?.question === "string" ? raw.question : "";
    const options = (Array.isArray(raw?.options) ? (raw.options as Record<string, unknown>[]) : [])
      .filter((o) => typeof o?.label === "string" && o.label)
      .map((o) => ({ label: o.label as string, description: typeof o.description === "string" ? o.description : "" }));
    if (!question || question.endsWith("…") || options.length < 2) return null;
    out.push({ question, options, multiSelect: raw.multiSelect === true });
  }
  return out.length > 0 ? out : null;
}

function saveSettings() {
  void Bridge.saveSettings(State.settings);
}

class Chat {
  /** Port: the views drawing this chat (the chat view, the tab's home chat). */
  private views: ChatHooks[] = [];
  /** The view that sent the answer in flight: it gets the field back after. */
  private sender: ChatHooks | null = null;
  /** Port: the island view the picker was opened from ("prompt" or the home chat's "overview"/"empty"). */
  pickerView = "prompt";
  /** Port: where the chat goes back to after one of its cards. */
  private sentFrom: IslandViewName = "prompt";

  /** The one-view API PromptView started with: replaces every view. */
  get hooks(): ChatHooks | null { return this.views[0] ?? null; }
  set hooks(h: ChatHooks | null) { this.views = h ? [h] : []; }
  addHooks(h: ChatHooks) { if (!this.views.includes(h)) this.views.push(h); }
  /** Port: every chat field takes the keyboard (the one on screen keeps it). */
  focusViews() { for (const v of this.views.slice()) v.focusInput(); }
  removeHooks(h: ChatHooks) {
    this.views = this.views.filter((v) => v !== h);
    if (this.sender === h) this.sender = null;
  }

  /** Port: bumped when another chat is reopened in place (the log is redrawn whole). */
  generation = 0;

  // ── Port: conversations side by side (his ask: multitasking) ──
  // ambxst-robo keeps every conversation talked in (chat.rs Chats), each
  // answering on its own; one is on the chat page. Each has its own log, its
  // answer on its way and its queued messages; the page's log IS
  // State.chatHistory (the same array). Each one talked in has a pill: its
  // mini in the island, focused while it is on the page.

  /** ambxst-robo's id of the conversation on the chat page ("" until known). */
  conv = "";
  private convs = new Map<string, Conv>();

  /** The page's conversation. */
  private cur(): Conv {
    let c = this.convs.get(this.conv);
    if (!c) {
      c = newConv(State.chatHistory);
      this.convs.set(this.conv, c);
    }
    return c;
  }

  /** An answer is on its way in the page's conversation. */
  get sending() { return this.cur().sending; }
  set sending(v: boolean) { this.cur().sending = v; }
  /** A local model's answer so far (chat.ts `live`), null when none is streaming. */
  get live() { return this.cur().live; }
  set live(v: string | null) { this.cur().live = v; }
  /**
   * Port (his ask): the page's answer is streaming right now. `live` stays
   * up for the whole turn (the text before a tool call is kept until the
   * next text replaces it), so Robo's talking face follows the deltas
   * instead: new text in the last SPEAK_HOLD_MS, no tool started since.
   */
  /** Port (his ask): the page's turn has a tool running right now. */
  toolRunning(): boolean {
    const c = this.cur();
    return c.sending && (c.tools ?? 0) > 0;
  }
  speaking(): boolean {
    const c = this.cur();
    return c.sending && c.live !== null && performance.now() - (c.liveAt ?? 0) < SPEAK_HOLD_MS;
  }

  // ── Picker (buildPicker) ──
  pickerOpen = false;
  /** picker-status line: text + whether "Open Settings" follows it; null = model rows. */
  pickerStatus: { text: string; withSettings: boolean } | null = null;
  pickerAccent = "#C0C4CC";
  pickerModels: PickerRow[] = [];
  /** Port: a status-style line under the model rows ("" = none), for Claude Code. */
  pickerNote = "";
  /** Port: Claude Code's permission modes under its models (empty for other providers). */
  pickerModes: PickerModeRow[] = [];
  pickerModesTitle = "";
  /** Port: what the chosen mode does, a line under the models ("" = none). */
  pickerModeHint = "";
  /** The request id of the card the chat put up, while it is up. */
  private cardRequest: string | null = null;
  private cache = new Map<string, ModelInfo[]>();
  private request = 0;

  constructor() {
    // The log's compaction bar comes and goes with Claude Code's compaction.
    Compaction.onChange(() => {
      this.changed();
      this.heightChanged();
    });
    void ensureDefaultProvider().then(() => {
      migrateModel();
      this.changed();
    });
    // Port: the agent moving on (a tool, a compaction, a card) ends Robo's
    // talking at once; the streamed text stays on the page.
    void onEvent<{ coucou_conv?: string; coucou_helper?: unknown; hook_event_name?: string }>("hook", (p) => {
      if (!p?.coucou_conv || p.coucou_helper) return;
      const c = this.convs.get(p.coucou_conv);
      if (!c) return;
      // Port (his ask): tools running right now (parallel calls counted), so
      // Robo shows his working face during a tool and thinks between them.
      const ev = p.hook_event_name;
      if (ev === "PreToolUse") c.tools = (c.tools ?? 0) + 1;
      else if (ev === "PostToolUse" || ev === "PostToolUseFailure") c.tools = Math.max(0, (c.tools ?? 0) - 1);
      else if (ev === "UserPromptSubmit" || ev === "Stop" || ev === "ChatTurnDone") c.tools = 0;
      if (ev === "UserPromptSubmit") return;
      c.liveAt = 0;
      c.hushUntil = performance.now() + SPEAK_HUSH_MS;
    });
    void onEvent<ChatPermission>("chat-permission", (p) => this.showCard(p));
    void onEvent<{ request_id?: string }>("chat-permission-gone", (p) => this.cardGone(p?.request_id ?? ""));
    // Port: `{conv, text}` (a conversation answering off the page keeps its own).
    void onEvent<string | { conv?: string; text?: string }>("chat-delta", (d) => {
      const text = typeof d === "string" ? d : d?.text ?? "";
      const conv = typeof d === "string" ? this.conv : d?.conv ?? this.conv;
      const c = conv === this.conv ? this.cur() : this.convs.get(conv);
      if (!c || !c.sending || !text) return; // nothing visible yet: the dots stay
      // Port: Robo talks only while new text comes (speaking()); the last
      // characters core flushes as a tool call starts don't count.
      if (text !== c.live && performance.now() >= (c.hushUntil ?? 0)) c.liveAt = performance.now();
      c.live = text;
      if (conv === this.conv) this.changed();
    });
    // Port (his ask): Claude Code took in a message typed while it worked
    // (claude_code.rs, its echo of it): the answer so far stays in the log,
    // the message joins it below that from the queue, and the answer
    // streams on under it.
    void onEvent<{ conv?: string; text?: string }>("chat-injected", (d) => {
      const conv = d?.conv ?? this.conv;
      const c = conv === this.conv ? this.cur() : this.convs.get(conv);
      if (!c || !d?.text) return;
      let i = c.queued.findIndex((q) => q.inCore && q.content === d.text);
      if (i < 0) i = c.queued.findIndex((q) => q.content === d.text);
      if (i < 0) i = c.queued.findIndex((q) => q.inCore);
      const said = (c.live ?? "").trim();
      if (said) c.history.push({ id: nextId++, role: "assistant", content: said });
      c.live = null;
      const [q] = i >= 0 ? c.queued.splice(i, 1) : [];
      c.history.push({ id: nextId++, role: "user", content: q?.content ?? d.text });
      if (conv === this.conv) {
        this.changed();
        this.heightChanged();
      }
      State.notify();
    });
    // Port (his ask): a note in a conversation's log from ambxst-robo (its
    // working directory is gone), and the folder chip following the settings.
    void onEvent<{ conv?: string; text?: string }>("chat-note", (n) => {
      this.workDirConv = null;
      if (n?.text) this.note(n.text, n.conv ?? this.conv);
    });
    void onEvent("settings-changed", () => {
      this.workDirConv = null;
      this.syncWorkDir();
    });
    // sync(): leaving the chat folds the picker away.
    State.subscribe(() => {
      if (State.view !== this.pickerView && this.pickerOpen) this.closePicker();
      // The card was answered (or folded into the answer): the reply carries
      // on, so the chat comes back to show it.
      if (this.cardRequest && State.pendingApproval?.requestId !== this.cardRequest) {
        this.cardRequest = null;
        if (this.sending) {
          window.setTimeout(() => {
            if (this.sending && !State.pendingApproval && State.mode === "expanded") island?.setView(this.sentFrom);
          }, 0);
        }
      }
    });
  }

  private changed() {
    for (const v of this.views.slice()) v.changed();
  }

  /** buildViews' onChatHeightChange: `() => this.animateGeometry(false)`. */
  private heightChanged() {
    (island as unknown as { animateGeometry(shrinking: boolean): void } | null)?.animateGeometry(false);
  }

  // ── Model button (drawModelButton) ──

  modelButton() {
    const p = providerDef(State.settings.chatProvider);
    const model = activeModel(State.settings);
    // Port: Claude Code shows its model's name and the permission mode.
    const name = p.id === CLAUDE_CODE_ID && model
      ? `${modelLabel(model)} · ${t(CHAT_MODES.find((m) => m.id === chatMode())!.label)}`
      : model;
    return {
      accent: p.accent,
      name: name || t(STRINGS.noModel),
      open: this.pickerOpen,
      disabled: this.sending,
    };
  }

  modelButtonClicked(where = "prompt") {
    if (this.sending) return;
    if (this.pickerOpen) this.closePicker();
    else this.openPicker(where);
  }

  // ── Picker ──

  chips(): PickerChip[] {
    return visibleProviders(State.settings).map((p) => ({
      id: p.id, name: t(p.name), accent: p.accent, on: p.id === State.settings.chatProvider,
    }));
  }

  chipClicked(id: string) {
    if (id === State.settings.chatProvider) return;
    State.settings = { ...State.settings, chatProvider: id as never };
    saveSettings();
    Sound.play("pop");
    void this.loadModels();
    this.changed();
  }

  private status(text: string, withSettings = false) {
    this.pickerStatus = { text, withSettings };
    this.pickerNote = "";
    this.pickerModels = [];
    this.pickerModes = [];
    this.pickerModesTitle = "";
    this.pickerModeHint = "";
    this.changed();
  }

  private drawModels(p: ProviderDef, models: ModelInfo[]) {
    const current = activeModel(State.settings);
    this.pickerStatus = null;
    // Port: Claude Code needs no key; a line under its models says what it uses.
    this.pickerNote = p.id === CLAUDE_CODE_ID ? t(SUBSCRIPTION_NOTE) : "";
    this.pickerAccent = p.accent;
    this.pickerModels = models.map((m) => ({ id: m.id, label: m.label, on: m.id === current }));
    this.drawModes();
    this.changed();
  }

  /** Port: Claude Code's permission modes, as rows under its models. */
  private drawModes() {
    const claude = providerDef(State.settings.chatProvider).id === CLAUDE_CODE_ID && this.pickerStatus === null;
    const mode = chatMode();
    this.pickerModesTitle = claude ? t(MODES_TITLE) : "";
    this.pickerModes = claude
      ? CHAT_MODES.map((m) => ({ id: m.id, label: t(m.label), hint: t(m.hint), on: m.id === mode }))
      : [];
    const on = this.pickerModes.find((m) => m.on);
    this.pickerModeHint = on ? `${on.label}: ${on.hint}` : "";
  }

  /** Port: a mode row was clicked. The picker stays open (a model may follow). */
  modeClicked(id: string) {
    if (this.sending || id === chatMode()) return;
    setChatMode(id as ChatModeId);
    Sound.play("blip");
    this.drawModes();
    this.changed();
  }

  modelClicked(id: string) {
    const p = providerDef(State.settings.chatProvider);
    State.settings = withModel(State.settings, p.id, id);
    saveSettings();
    Sound.play("blip");
    this.closePicker();
  }

  openSettings() {
    void Bridge.openSettingsWindow();
  }

  private async loadModels() {
    const ticket = ++this.request;
    // Port: the default provider may still be settling (claudecode.ts).
    await ensureDefaultProvider();
    if (ticket !== this.request) return;
    const p = providerDef(State.settings.chatProvider);
    const cached = p.urlField ? undefined : this.cache.get(p.id);
    if (cached) {
      this.drawModels(p, cached);
      return;
    }
    // Nothing is asked of a provider that has no key yet.
    if (p.key && !(await Bridge.secretPresent(p.key))) {
      if (ticket === this.request) this.status(t(STRINGS.noKey), true);
      return;
    }
    if (ticket !== this.request) return;
    this.status(t(STRINGS.loading));
    try {
      const models = await Bridge.chatModels(p.id);
      if (ticket !== this.request) return;
      if (!p.urlField) this.cache.set(p.id, models);
      if (p.id === CLAUDE_CODE_ID) migrateModel();
      const keep = pickModel(p, models.map((m) => m.id), activeModel(State.settings));
      if (keep && keep !== activeModel(State.settings)) {
        State.settings = withModel(State.settings, p.id, keep);
        saveSettings();
        this.changed();
      }
      this.drawModels(p, models);
    } catch (err) {
      if (ticket === this.request) this.status(String(err).replace(/^Error:\s*/, ""), Boolean(p.key));
    }
  }

  openPicker(where = "prompt") {
    this.pickerView = where;
    this.pickerOpen = true;
    this.changed();
    void this.loadModels();
  }

  closePicker() {
    this.pickerOpen = false;
    this.request++;
    this.changed();
  }

  // ── Permission cards of the chat's own Claude Code run (port) ──

  /**
   * hooks.ts PermissionRequest, for the chat: the same Allow/Deny or question
   * card, on a "Chat" pill made for it. One card at a time; paused or another
   * card up → declined at once (the run is told no).
   */
  private showCard(p: ChatPermission) {
    const requestId = p.request_id ?? "";
    if (!requestId) return;
    const tool = p.tool_name ?? "Tool";
    const input = p.tool_input ?? {};
    const questions = askedQuestions(tool, input);
    // A question the card can't show as options can't be answered here.
    if (State.paused || (tool === "AskUserQuestion" && !questions)
        || (State.pendingApproval && State.pendingApproval.requestId !== requestId)) {
      void Bridge.approvalDecline(requestId);
      return;
    }
    // Port: on its conversation's pill (its mini); the "Chat" pill otherwise.
    const convPill = p.coucou_conv && State.tasks.some((x) => x.id === convPillId(p.coucou_conv!)) ? convPillId(p.coucou_conv) : null;
    const pillId = convPill ?? CHAT_PILL_ID;
    if (!convPill) State.upsertExternalAgent(CHAT_PILL_ID, t(CHAT_PILL_NAME), CLAUDE_CODE.accent);
    const view = questions ? "question" : "approval";
    State.beginApproval({
      requestId,
      sessionId: p.session_id ?? "",
      pillId,
      tool,
      command: approvalTarget(tool, input),
      ...(questions ? { questions } : {}),
    });
    this.cardRequest = requestId;
    // Port: ambxst-robo gives an unanswered card up after 108 s and says so
    // (chat-permission-gone); like hooks.ts pendingTimeout, the island drops it
    // by itself a little later in case that never arrives (core restarted).
    window.setTimeout(() => this.cardGone(requestId), CHAT_CARD_TIMEOUT_MS);
    // Synchronous from here: the card is up when the ack lands (800 ms window).
    void Bridge.approvalAck(requestId);
    State.updateTask(pillId, view);
    Sound.play(view);
    island?.alert(view);
    State.notify();
  }

  /** The run stopped waiting (timeout, ended, New chat): the card would be lying. */
  private cardGone(requestId: string) {
    if (!requestId || State.pendingApproval?.requestId !== requestId) return;
    this.cardRequest = null;
    // A no-op when ambxst-robo already let go; otherwise the run is told no.
    void Bridge.approvalDecline(requestId);
    State.endApproval();
    island?.dropPin();
    if (State.view === "approval" || State.view === "question") {
      island?.setView(this.sending ? this.sentFrom : State.defaultView());
    }
    if (!this.sending) this.dropChatPill();
    State.notify();
  }

  /** The reply is over: the chat's pill goes (and a card still up with it). */
  private dropChatPill() {
    if (this.cardRequest) {
      const id = this.cardRequest;
      this.cardRequest = null;
      void Bridge.approvalDecline(id);
      if (State.pendingApproval?.requestId === id) {
        State.endApproval();
        island?.dropPin();
        if (State.view === "approval" || State.view === "question") island?.setView(State.defaultView());
      }
    }
    if (State.tasks.some((x) => x.id === CHAT_PILL_ID)) State.removeTask(CHAT_PILL_ID);
  }

  /** Port: State.chatHistory was replaced by a reopened chat (lib/views/history.ts). */
  reloaded() {
    this.generation++;
    this.live = null;
    this.changed();
    this.heightChanged();
  }

  // ── Log (sync) ──

  /** The rows the log shows: the history, then the streamed answer or the dots. */
  rows(): { role: string; content: string; typing?: boolean; key?: string }[] {
    const out: { role: string; content: string; typing?: boolean; key?: string; intro?: boolean }[] = State.chatHistory.map((m) => ({
      role: m.role, content: m.content, intro: (m as { intro?: boolean }).intro,
    }));
    if (this.live !== null) out.push({ role: "assistant", content: this.live });
    else if (State.stateOverride === "thinking" && !Compaction.running(this.conv)) out.push({ role: "assistant", content: "", typing: true });
    // Port (his ask): Claude Code compacting this conversation: its shimmering
    // line under the latest one (ChatRow).
    if (Compaction.progress(this.conv) >= 0) out.push({ role: "compacting", content: "", key: this.conv });
    return out;
  }

  /** Port (his ask): Claude Code compacted `conv`: the marker where it happened. */
  noteCompacted(conv: string) {
    const c = conv === this.conv ? this.cur() : this.convs.get(conv);
    if (!c) return;
    const last = c.history[c.history.length - 1];
    if (!last || last.role !== "compact") c.history.push({ id: nextId++, role: "compact", content: "" });
    if (conv === this.conv) {
      this.changed();
      this.heightChanged();
    }
    State.notify();
  }

  placeholder() {
    return t(State.chatHistory.length === 0 ? STRINGS.placeholderFirst : STRINGS.placeholderNext);
  }

  /** The chip's label: a dropped file's name, or "". */
  chipLabel() {
    return State.droppedFile?.name ?? "";
  }

  /** Port: a file dropped into an ongoing chat waits by the field for the next message. */
  chipInChat() {
    return !!State.droppedFile && State.dropInChat === true;
  }

  /** Port: the in-chat chip's ×. */
  detachFile() {
    if (!this.chipInChat()) return;
    State.droppedFile = null;
    State.promptContext = null;
    this.dropDir = null;
    Sound.play("blip");
    State.notify();
  }

  // ── Send (submit) ──

  /**
   * Returns true when the text was taken (the field is then emptied). Port:
   * `from` = the sending view's hooks and island view (the home chat sends
   * from the overview), so its field gets the keyboard back and a card's
   * answer returns there.
   */
  submit(text: string, from?: ChatHooks, where: IslandViewName = "prompt"): boolean {
    const query = text.trim();
    if (!query) return false;
    // Port: typed while an answer comes. Claude Code folds it into the
    // running turn; a provider that can't takes it as the next message.
    if (this.sending) {
      void this.inject(query);
      return true;
    }
    if (this.pickerOpen) this.closePicker();
    this.sender = from ?? null;
    this.sentFrom = where;
    this.sending = true;
    void this.send(query);
    return true;
  }

  /** Port: messages typed during an answer, until it takes them in or is done. */
  get queued() { return this.cur().queued; }
  set queued(v: Queued[]) { this.cur().queued = v; }

  /**
   * Port: the queued messages, as the log shows them: under the working
   * line, dimmed, each with its caption (ChatRow).
   */
  queuedRows(): { role: string; content: string; queued: true; caption: string }[] {
    return this.queued.map((q) => ({ role: "user", content: q.content, queued: true, caption: t(q.caption) }));
  }

  /** Port: the stop button (shown while an answer comes and the field is empty). */
  stop() {
    if (!this.sending) return;
    // Port: a turn typed into the session's terminal runs there: the page
    // stops waiting for it (the terminal keeps its own Esc).
    const c = this.cur();
    if (c.terminal) {
      c.terminal = false;
      c.sending = false;
      State.stateOverride = null;
      this.changed();
      State.notify();
      return;
    }
    void invoke<boolean>("chat_stop", this.conv ? { conv: this.conv } : {}).catch(() => false);
  }

  /**
   * Port (his ask): typed while the answer comes. It waits under the working
   * line until Claude Code takes it in (chat-injected moves it into the log
   * then). One Claude Code's turn doesn't take (another provider, or the turn
   * ended first) goes as the next turn; so does one it never took in before
   * its turn ended, stopped or not (see send's finally).
   */
  private async inject(query: string) {
    const conv = this.conv;
    const c = this.cur();
    const q = queuedOf(query, false);
    c.queued.push(q);
    this.changed();
    State.notify();
    this.heightChanged();
    let taken = false;
    try {
      taken = await invoke<boolean>("chat_inject", conv ? { text: query, conv } : { text: query });
    } catch {
      taken = false;
    }
    if (taken && c.sending && c.queued.includes(q)) {
      q.inCore = true;
      Sound.play("send");
    }
    if (conv === this.conv) this.changed();
  }

  /**
   * One turn in conversation `conv` (the page's by default). It may leave the
   * page before the answer lands (another chat opened, New chat): the answer
   * then goes into that conversation's own log, and its mini says it is done.
   */
  /**
   * Port (his ask): a reply typed into the finished popup about a chat
   * conversation: sent to that conversation, wherever the page is (queued
   * when it is still answering). False when it is gone.
   */
  replyTo(conv: string, text: string): boolean {
    const query = text.trim();
    if (!query) return false;
    if (conv === this.conv) return this.submit(query);
    const c = this.convs.get(conv);
    if (!c) return false;
    if (c.sending) c.queued.push(queuedOf(query, false));
    else void this.send(query, conv);
    return true;
  }

  private async send(query: string, conv = this.conv) {
    const c = conv === this.conv ? this.cur() : this.convs.get(conv);
    if (!c) return;
    const onPage = () => conv === this.conv && this.convs.get(conv) === c;
    c.sending = true;
    this.changed();
    Sound.play("send");

    c.history.push({ id: nextId++, role: "user", content: query });
    if (onPage()) State.stateOverride = "thinking";
    const pill = this.pillFor(conv, c);
    if (pill) {
      State.updateTask(pill, "thinking");
      if (onPage()) State.setFocus(pill);
    }
    State.notify();
    this.heightChanged();

    // Port: a file goes with the message that follows its drop, the first or
    // a later one (dropped into an ongoing chat); then it is spent.
    const file = onPage() ? State.droppedFile : null;
    const context: ChatContext | null = file ? { kind: "file", name: file.name, path: file.path } : null;
    if (file && c.history.length > 1) { State.droppedFile = null; State.promptContext = null; }
    // Port (his ask): a dropped folder sent along is no longer offered as the working directory.
    if (file) this.dropDir = null;

    // Port (his ask): a Claude Code session that is open in a kitty terminal
    // gets the message typed into that terminal (ambxst-robo session_reply.rs),
    // not a second run of the session beside it. Its answer comes back with
    // the session's Stop (main.ts → terminalDone). Anywhere else (no terminal,
    // a file to send along): Robo runs the turn, as before.
    // Port (his ask): Remote Control on: the message is typed into the
    // session it runs (the phone sees it too); its answer comes back as the
    // conversation's ChatTurnDone (terminalDone), as a terminal's does.
    if (conv && !context && Remote.isOn(conv)) {
      try {
        c.terminal = true;
        await Remote.send(conv, query);
        if (this.convs.get(conv) !== c) return;
        void invoke("chat_talked", { conv }).then(() => this.refreshConvs()).catch(() => {});
        return;
      } catch {
        c.terminal = false;
        // Its process is gone: Robo runs the turn, as before.
      }
    }
    const sid = !context && c.key?.startsWith("claude:") ? c.key.slice("claude:".length) : "";
    if (sid && conv) {
      try {
        await invoke<boolean>("session_reply", { sessionId: sid, text: query });
        if (this.convs.get(conv) !== c) return;
        c.terminal = true;
        void invoke("chat_talked", { conv }).then(() => this.refreshConvs()).catch(() => {});
        return;
      } catch {
        // Not running in a terminal Robo can type into.
      }
    }

    const provider = State.settings.chatProvider;
    let failed = false;
    try {
      await ensureDefaultProvider();
      type Reply = { text: string; stopped?: boolean; conv?: string };
      let reply: Reply;
      try {
        reply = await invoke<Reply>("chat_send", conv ? { query, context, conv } : { query, context });
      } catch (err) {
        // Port (his bug): ambxst-robo restarted under this island, so its id
        // for the chat is gone ("That conversation is closed."): the chat is
        // reopened from its card under its new id, and the message goes there.
        const again = conv && /conversation is closed/i.test(String(err)) ? await this.revive(conv, c) : null;
        if (!again) throw err;
        conv = again;
        reply = await invoke<Reply>("chat_send", { query, context, conv });
      }
      // The page's conversation got its id from this answer (an older core
      // or an island that started before core said which it was).
      if (!conv && reply.conv && this.convs.get("") === c) {
        this.convs.delete("");
        this.convs.set(reply.conv, c);
        if (this.conv === "") this.conv = reply.conv;
        conv = reply.conv;
      }
      if (this.convs.get(conv) !== c) return; // retired meanwhile
      if (reply.stopped) {
        // Stopped: what had come stays (Claude Code's is in its session too).
        const text = (reply.text || c.live || "").trim();
        if (text) c.history.push({ id: nextId++, role: "assistant", content: text });
        // A `/compact` turn (core answers it as stopped, quietly): no
        // finished turn comes, its mini goes straight back to idle (his ask).
        else if (State.tasks.some((x) => x.id === convPillId(conv))) State.updateTask(convPillId(conv), "idle");
      } else {
        c.history.push({ id: nextId++, role: "assistant", content: reply.text });
        Sound.play("finish");
      }
      if (onPage()) State.stateOverride = null;
    } catch (err) {
      failed = true;
      if (this.convs.get(conv) !== c) return;
      const message = String(err).replace(/^Error:\s*/, "");
      if (onPage()) {
        State.stateOverride = null;
        State.noteMessage = message;
        State.view = "note";
      } else {
        const p = this.pillFor(conv, c);
        if (p) State.appendStep(p, `⚠ ${message}`);
      }
      Sound.play("error");
    } finally {
      const mine = this.convs.get(conv) === c;
      c.sending = false;
      if (mine) this.flushRemote(conv);
      c.live = null; // the finished answer replaces the streamed one
      if (mine) {
        // Claude Code's turn ends with its ChatTurnDone hook (main.ts); the
        // other providers send none, so their mini finishes here.
        if (provider !== CLAUDE_CODE_ID || failed) this.finishPill(conv);
        void this.refreshConvs();
        // Port (his ask): the turn may have pinned (or lost) its working directory.
        if (conv === this.conv) this.workDirConv = null;
      }
      if (onPage()) {
        this.dropChatPill();
        this.changed();
        State.notify();
        this.heightChanged();
        const sender = this.sender;
        this.sender = null;
        if (sender) sender.focusInput();
        else for (const v of this.views.slice()) v.focusInput();
      } else {
        State.notify();
      }
      // Port: what was typed meanwhile and not taken in by the turn goes
      // now, as one message.
      if (mine && c.queued.length) {
        const next = joinedQueue(c.queued);
        c.queued = [];
        if (onPage()) {
          const where = this.sentFrom;
          window.setTimeout(() => this.submit(next, undefined, where), 0);
        } else {
          c.sending = true;
          window.setTimeout(() => void this.send(next, conv), 0);
        }
      }
    }
  }

  // ── Port: the conversations' pills (their minis) ──

  /** The pill of conversation `conv`, made if it has none yet; null without an id. */
  private pillFor(conv: string, c: Conv): string | null {
    if (!conv) return null;
    const id = convPillId(conv);
    const title = c.title || titleOf(c.history) || t(CHAT_PILL_NAME);
    if (!State.tasks.some((x) => x.id === id)) {
      State.upsertExternalAgent(id, title, providerDef(State.settings.chatProvider).accent);
      // Its card shows where it was left: the last answer's first line.
      const last = [...c.history].reverse().find((m) => m.role === "assistant");
      const line = last ? toOneLine(last.content) : "";
      if (line) {
        State.appendStep(id, line);
        const made = State.tasks.find((x) => x.id === id) as ConvTask | undefined;
        if (made) made.finalLine = line;
      }
    }
    const task = State.tasks.find((x) => x.id === id) as ConvTask | undefined;
    if (task) {
      task.conv = conv;
      if (c.title || task.name === t(CHAT_PILL_NAME)) task.name = title;
    }
    return id;
  }

  /** Port: the pill of `conv` exists (a hook of it came before anything else). */
  ensureConvPill(conv: string) {
    if (State.tasks.some((x) => x.id === convPillId(conv))) return;
    let c = this.convs.get(conv);
    if (!c) {
      c = newConv([]);
      c.stale = true;
      c.sending = true;
      this.convs.set(conv, c);
      this.watchPending(conv);
    }
    this.pillFor(conv, c);
    void this.refreshConvs();
  }

  /**
   * Port: the session of `conv` finished the turn typed into its terminal
   * (its Stop, main.ts): its whole answer joins the log.
   */
  async terminalDone(conv: string, said = "") {
    const c = this.convs.get(conv);
    if (!c || !c.terminal) return;
    const sid = c.key?.startsWith("claude:") ? c.key.slice("claude:".length) : (Remote.stateOf(conv)?.sessionId ?? "");
    let text = "";
    // (The Stop hook can come before the transcript has the answer: read it
    // again a moment later; the hook's own copy of the answer stands in.)
    const before = c.history.length ? c.history[c.history.length - 1].content : "";
    for (let i = 0; i < 3 && sid; i++) {
      try {
        text = (await invoke<string | null>("session_last_reply", { sessionId: sid })) ?? "";
      } catch { text = ""; }
      if (text && text !== before) break;
      text = "";
      await new Promise((r) => window.setTimeout(r, 400));
    }
    if (!text) text = said;
    if (this.convs.get(conv) !== c) return;
    const onPage = conv === this.conv;
    c.terminal = false;
    c.sending = false;
    c.live = null;
    this.flushRemote(conv);
    if (text) c.history.push({ id: nextId++, role: "assistant", content: text });
    if (onPage) {
      State.stateOverride = null;
      Sound.play("finish");
      this.changed();
      this.heightChanged();
    }
    State.notify();
    if (c.queued.length) {
      const next = joinedQueue(c.queued);
      c.queued = [];
      if (onPage) window.setTimeout(() => this.submit(next, undefined, this.sentFrom), 0);
      else { c.sending = true; window.setTimeout(() => void this.send(next, conv), 0); }
    }
  }

  /**
   * Port (his ask): a message sent to `conv`'s Remote Control session from
   * elsewhere (the phone, claude.ai): shown as the user's, its answer awaited.
   * One typed here already shows (c.terminal).
   */
  remotePrompt(conv: string, prompt: string) {
    const c = this.convs.get(conv);
    if (!c || c.terminal || !prompt.trim()) return;
    c.history.push({ id: nextId++, role: "user", content: prompt });
    c.terminal = true;
    c.sending = true;
    if (conv === this.conv) {
      State.stateOverride = "thinking";
      this.changed();
      this.heightChanged();
    }
    State.notify();
  }

  // ── Port (his ask): the working directory (the folder chip) ──
  // Claude Code's turns run in a folder: Robo's own by default, or one the
  // user picks (the chip's folder chooser, or a dropped folder's "Use as
  // working directory"). ambxst-robo keeps it (settings `chatWorkDir`, for
  // new chats) and each conversation keeps its own (its session lives there).

  /** What ambxst-robo said of the page's conversation's folder (null = not yet). */
  workDir: WorkDirInfo | null = null;
  /** The conversation `workDir` is about (null = ask again). */
  private workDirConv: string | null = null;
  /** The folder chooser is open. */
  workDirPicking = false;
  /** A dropped folder (its own path) that may become the working directory. */
  dropDir: { path: string; name: string; failed: boolean } | null = null;
  /** The path of the last drop (files_dropped tells whether it is a folder). */
  private lastDrop = "";

  /**
   * Asks ambxst-robo again when the page's conversation changed (or a turn,
   * the settings, a note made it stale). Called by the views on every redraw
   * (a handler, not a binding: a core call bumps the host's ids).
   */
  syncWorkDir() {
    if (this.workDirConv === this.conv) return;
    const conv = this.conv;
    this.workDirConv = conv;
    invoke<WorkDirInfo>("chat_work_dir", conv ? { conv } : {})
      .then((r) => {
        if (this.workDirConv !== conv || !r) return;
        this.workDir = r;
        this.changed();
      })
      .catch(() => {});
  }

  /** The folder chip (Claude Code's chats only, like Remote Control). */
  workDirChip(): WorkDirChip {
    const w = this.workDir;
    const show = State.settings.chatProvider === CLAUDE_CODE_ID && w !== null;
    const isDefault = !w || w.isDefault;
    const label = isDefault ? t(STRINGS.workDirDefault) : workDirLabel(w!.path, this.home, w!.name);
    const where = isDefault ? t("Robo's own folder") : w!.path;
    const tooltip = `${t(STRINGS.workDir)}: ${where}` + (isDefault ? "" : `\n${t("Right-click to go back to the default")}`)
      + (w?.path ? `\n${t("Middle-click to copy the path")}` : "");
    return { show, label, tooltip, path: w?.path ?? "", isDefault, disabled: this.sending || this.workDirPicking };
  }

  /** The user's home folder ($HOME, from the shell: ChatPanel), for the chip's `~`. */
  home = "";
  setHome(home: string) {
    const h = String(home || "").replace(/\/+$/, "");
    if (!h || h === this.home) return;
    this.home = h;
    this.changed();
  }

  /** A folder was set: the chip shows it; a conversation moved says so in its log. */
  private workDirSet(r: WorkDirInfo) {
    this.workDir = r;
    this.workDirConv = this.conv;
    if (r.moved) {
      const where = r.isDefault ? t("Robo's own folder") : workDirLabel(r.path, this.home, r.name);
      this.note(t("Working directory: {where}. Claude Code continues this chat there, in a new session.", { where }));
    }
    this.changed();
  }

  /**
   * The chip's click: the desktop's folder chooser (ambxst-robo). Resolves
   * once it is closed, picked or not (the view brings the tab back then).
   */
  async pickWorkDir(): Promise<void> {
    if (this.sending || this.workDirPicking) return;
    this.workDirPicking = true;
    this.changed();
    try {
      const r = await invoke<WorkDirInfo>("chat_pick_work_dir", this.conv ? { conv: this.conv } : {});
      if (r?.picked) this.workDirSet(r);
      else if (r) this.workDir = r;
    } catch (err) {
      this.note(String(err).replace(/^Error:\s*/, ""));
    } finally {
      this.workDirPicking = false;
      this.changed();
    }
  }

  /** The chip's right-click: back to Robo's own folder. */
  resetWorkDir() {
    if (this.sending || this.workDirPicking || !this.workDir || this.workDir.isDefault) return;
    void this.setWorkDir("");
  }

  /** `path` ("" = the default) becomes the working directory. */
  async setWorkDir(path: string): Promise<boolean> {
    try {
      const r = await invoke<WorkDirInfo>("chat_set_work_dir", this.conv ? { path, conv: this.conv } : { path });
      if (r) this.workDirSet(r);
      return true;
    } catch (err) {
      this.note(String(err).replace(/^Error:\s*/, ""));
      return false;
    }
  }

  /** A note under the latest row of conversation `conv`'s log (not a turn: no one sees it but the user). */
  private note(text: string, conv = this.conv) {
    // (The page's log is State.chatHistory: cur().history is the same array once the page has synced.)
    const list = conv === this.conv ? State.chatHistory : this.convs.get(conv)?.history;
    if (!list) return;
    list.push({ id: nextId++, role: "note", content: text } as never);
    if (conv === this.conv) {
      this.changed();
      this.heightChanged();
    }
    State.notify();
  }

  /** A drop (island.ts): its path, until files_dropped says whether it is a folder. */
  dropped(path: string) {
    this.lastDrop = path;
    this.dropDir = null;
  }

  /** files_dropped's answer (Robo.qml): the dropped paths that are folders. */
  droppedDirs(dirs: string[]) {
    if (!this.lastDrop || !dirs.includes(this.lastDrop)) return;
    const name = this.lastDrop.split(/[\\/]/).filter(Boolean).pop() || this.lastDrop;
    this.dropDir = { path: this.lastDrop, name, failed: false };
    this.changed();
    State.notify();
  }

  /**
   * The drop's copy failed (a folder too big to copy, say): a folder can still
   * become the working directory. True when it is one (the chat page shows the offer).
   */
  dropFailed(path: string): boolean {
    if (!this.dropDir || this.dropDir.path !== path) return false;
    this.dropDir.failed = true;
    this.changed();
    return true;
  }

  /**
   * Port (his ask): ambxst-robo refused the drop because it is a folder too
   * big to copy (files.rs ingest_folder). Claude Code's chats then take it as
   * their working directory instead (folderAsWorkDir), no question asked.
   */
  folderTooBig(message: string): boolean {
    if (State.settings.chatProvider !== CLAUDE_CODE_ID) return false;
    return message === FOLDER_TOO_BIG || message === t(FOLDER_TOO_BIG);
  }

  /**
   * The folder too big to attach becomes the working directory, with a note
   * in the chat saying so. `before`: the fresh chat a drop on an empty chat
   * starts (its note goes in that one).
   */
  async folderAsWorkDir(path: string, before?: Promise<unknown>): Promise<void> {
    try { await before; } catch { /* the reset's own failure is handled there */ }
    this.dropDir = null;
    if (!(await this.setWorkDir(path))) return;
    this.note(t(STRINGS.tooBigWorkDir));
    Sound.play("approve");
  }

  /** The drop was asked about, sent, taken back or cancelled: the offer goes. */
  dropSettled() {
    if (!this.dropDir) return;
    this.dropDir = null;
    this.changed();
  }

  /** "Use as working directory" shows for the dropped folder (not on the choose card's page). */
  dropOffer(): string {
    const d = this.dropDir;
    if (!d || (!State.droppedFile && !d.failed)) return "";
    return t(STRINGS.useAsWorkDir);
  }

  /**
   * "Use as working directory": the dropped folder becomes the working
   * directory instead of being attached (its copy is dropped).
   */
  async useDropAsWorkDir(): Promise<void> {
    const d = this.dropDir;
    if (!d || this.sending) return;
    if (!(await this.setWorkDir(d.path))) return;
    this.dropDir = null;
    State.droppedFile = null;
    State.promptContext = null;
    Sound.play("approve");
    if (State.view !== "prompt" && State.view !== "overview" && State.view !== "empty") island?.setView("prompt");
    this.changed();
    State.notify();
  }

  /** Port (his ask): the Remote Control button shows (Claude Code's chats only). */
  remoteAvailable(): boolean {
    return State.settings.chatProvider === CLAUDE_CODE_ID && this.conv !== "";
  }

  /**
   * Port (his ask): the Remote Control button: on (the chat's session, served
   * to the phone and claude.ai/code; its QR in the log, with how to get the
   * app the first time) or off.
   */
  async toggleRemote() {
    const conv = this.conv;
    if (!conv) return;
    // His ask: any time. While it answers, it comes on once the answer is
    // in (two Claude Codes can't share the session); a second click cancels.
    if (Remote.isQueued(conv)) {
      Sound.play("blip");
      Remote.setQueued(conv, false);
      return;
    }
    if (Remote.isStarting(conv)) return;
    if (!Remote.isOn(conv) && this.convs.get(conv)?.sending) {
      Sound.play("blip");
      Remote.setQueued(conv, true);
      return;
    }
    await this.startRemote(conv);
  }

  /** Port: a queued Remote Control comes on now that `conv`'s answer is in. */
  private flushRemote(conv: string) {
    if (!Remote.isQueued(conv)) return;
    Remote.setQueued(conv, false);
    window.setTimeout(() => void this.startRemote(conv), 300);
  }

  private async startRemote(conv: string) {
    if (Remote.isOn(conv)) {
      Sound.play("blip");
      await Remote.stop(conv);
      return;
    }
    Sound.play("blip");
    try {
      const st = await Remote.start(conv);
      const s = State.settings as unknown as { remoteIntroSeen?: boolean };
      this.noteRemote(conv, st.url ?? "", !s.remoteIntroSeen);
      if (!s.remoteIntroSeen) {
        s.remoteIntroSeen = true;
        void Bridge.saveSettings(State.settings);
      }
      Sound.play("pop");
    } catch (err) {
      Sound.play("error");
      // His ask: the note goes by itself (it stayed until another page).
      const message = String(err).replace(/^Error:\s*/, "");
      const back = State.view;
      State.noteMessage = message;
      State.view = "note";
      State.notify();
      window.setTimeout(() => {
        if (State.view === "note" && State.noteMessage === message && island) island.setView(back === "note" ? "prompt" : back);
      }, 4500);
    }
  }

  /** Port (his ask): Remote Control came on for `conv`: its card (QR, link) joins the log. */
  noteRemote(conv: string, url: string, intro: boolean) {
    const c = this.convs.get(conv);
    if (!c) return;
    c.history.push({ id: nextId++, role: "remote", content: url, intro } as never);
    if (conv === this.conv) {
      this.changed();
      this.heightChanged();
    }
    State.notify();
  }

  /** A turn is over: its pill says so, then goes back to idle (as after Stop, 5.2 s). */
  finishPill(conv: string, line = "") {
    const id = convPillId(conv);
    const task = State.tasks.find((x) => x.id === id) as ConvTask | undefined;
    if (!task) return;
    State.updateTask(id, "finished");
    if (line) {
      State.appendStep(id, line);
      task.finalLine = line;
    }
    window.setTimeout(() => {
      const x = State.tasks.find((y) => y.id === id);
      if (x && x.state === "finished") State.updateTask(id, "idle");
    }, 5200);
    State.notify();
  }

  /** ambxst-robo's titles and chats-column keys for the pills. */
  async refreshConvs() {
    let r: { convs: CoreConv[]; current: string };
    try {
      r = await invoke<{ convs: CoreConv[]; current: string }>("chat_conversations", {});
    } catch {
      return;
    }
    for (const x of r.convs ?? []) {
      const c = this.convs.get(x.conv);
      if (c) {
        c.title = x.title || c.title;
        c.key = x.key ? `${x.key.kind}:${x.key.id}` : c.key;
      }
      // Port (his ask): its look is kept under its durable key (lib/looks.ts).
      Looks.noteKey(x.conv, x.key ? `${x.key.kind}:${x.key.id}` : null);
      const task = State.tasks.find((y) => y.id === convPillId(x.conv)) as ConvTask | undefined;
      if (task) {
        if (x.title) task.name = x.title;
        task.convKey = x.key ? `${x.key.kind}:${x.key.id}` : null;
      }
    }
    State.notify();
  }

  /**
   * Makes `conv` the chat page's conversation. `r` is ambxst-robo's view of it
   * (chat_switch / chat_open / chat_current), used when this island holds
   * nothing newer. The one left stays (its turn runs on) if it has a mini.
   */
  adopt(conv: string, r: CoreChat | null, opts: { applyModel?: boolean } = {}) {
    const left = this.convs.get(this.conv);
    if (left && this.conv !== conv) {
      if (!left.sending && !State.tasks.some((x) => x.id === convPillId(this.conv))) this.convs.delete(this.conv);
    }
    if (this.pickerOpen) this.closePicker();
    this.conv = conv;
    let c = this.convs.get(conv);
    if (r && (!c || c.stale || (!c.sending && c.history.length === 0))) {
      const fresh = newConv(rowsOf(r));
      fresh.sending = !!r.pending;
      fresh.title = c?.title ?? "";
      fresh.key = c?.key ?? (r.current ? `${r.current.kind}:${r.current.id}` : null);
      c = fresh;
      this.convs.set(conv, c);
      if (r.pending) this.watchPending(conv);
    } else if (!c) {
      c = newConv([]);
      this.convs.set(conv, c);
    }
    State.chatHistory = c.history;
    State.stateOverride = c.sending ? "thinking" : null;
    State.droppedFile = null;
    State.promptContext = null;
    if (opts.applyModel !== false && r) applyModelOf(r);
    const pill = convPillId(conv);
    if (State.tasks.some((x) => x.id === pill)) State.setFocus(pill);
    this.reloaded();
    State.notify();
  }

  /** Port: a conversation's mini was clicked: its chat comes onto the page. */
  async openConv(conv: string): Promise<boolean> {
    if (conv !== this.conv) {
      let r: CoreChat;
      try {
        r = await invoke<CoreChat>("chat_switch", { conv });
      } catch {
        // Closed in ambxst-robo (restarted): reopened from its card (his
        // bug), else its mini goes.
        const c = this.convs.get(conv);
        const again = c ? await this.revive(conv, c) : null;
        if (!again) {
          this.forget(conv);
          return false;
        }
        try {
          r = await invoke<CoreChat>("chat_switch", { conv: again });
        } catch {
          return false;
        }
        conv = again;
      }
      this.adopt(conv, r);
      Sound.play("pop");
    }
    if (island && State.view !== "prompt" && !State.pendingApproval) island.setView("prompt");
    window.setTimeout(() => this.focusViews(), 160);
    return true;
  }

  /** Port: a mini dragged onto its card: its answer stops and it closes. */
  async retire(conv: string): Promise<boolean> {
    let r: { current: string };
    try {
      r = await invoke<{ current: string }>("chat_retire", { conv });
    } catch {
      return false;
    }
    const wasPage = conv === this.conv;
    this.forget(conv);
    if (wasPage) {
      State.chatHistory = [];
      this.adopt(r.current, { turns: [] });
    }
    State.notify();
    return true;
  }

  /** What this island holds of `conv` is out of date (ambxst-robo's wins on adopt). */
  markStale(conv: string) {
    const c = this.convs.get(conv);
    if (c && !c.sending) c.stale = true;
  }

  /** Drops what this island holds of `conv` and its pill. */
  forget(conv: string) {
    this.convs.delete(conv);
    const id = convPillId(conv);
    if (State.tasks.some((x) => x.id === id)) State.removeTask(id);
  }

  /**
   * Port (his bug): ambxst-robo restarted under this island: the chats it
   * reopened by itself (the current one) have new ids; each of ours is matched
   * to its card's (key) and takes its new id. The others revive when used.
   */
  async resync() {
    let list: CoreConv[];
    try {
      list = (await invoke<{ convs: CoreConv[] }>("chat_conversations", {})).convs ?? [];
    } catch {
      return;
    }
    for (const [conv, c] of Array.from(this.convs.entries())) {
      if (!conv || list.some((x) => x.conv === conv) || !c.key) continue;
      const now = list.find((x) => x.key && `${x.key.kind}:${x.key.id}` === c.key);
      if (!now) continue;
      this.convs.delete(conv);
      this.convs.set(now.conv, c);
      if (this.conv === conv) this.conv = now.conv;
      const was = State.tasks.find((x) => x.id === convPillId(conv));
      const state = was?.state;
      const focused = State.focusId === convPillId(conv);
      if (was) State.removeTask(was.id);
      Looks.noteKey(now.conv, c.key);
      const pill = this.pillFor(now.conv, c);
      if (pill && state) State.updateTask(pill, state as never);
      if (pill && focused) State.setFocus(pill);
    }
    State.notify();
  }

  /**
   * Port (his bug): `conv` is gone from ambxst-robo (it restarted): its chat
   * reopened from its card (key), under the id it has now; null if it has none.
   */
  private async revive(conv: string, c: Conv): Promise<string | null> {
    const key = c.key;
    if (!key || !key.includes(":")) return null;
    const at = key.indexOf(":");
    let r: { conv: string };
    try {
      r = await invoke<{ conv: string }>("chat_open", { kind: key.slice(0, at), id: key.slice(at + 1) });
    } catch {
      return null;
    }
    if (!r.conv || r.conv === conv) return null;
    this.convs.delete(conv);
    this.convs.set(r.conv, c);
    if (this.conv === conv) this.conv = r.conv;
    const was = State.tasks.find((x) => x.id === convPillId(conv));
    const state = was?.state ?? "thinking";
    if (was) State.removeTask(was.id);
    Looks.noteKey(r.conv, key);
    const pill = this.pillFor(r.conv, c);
    if (pill) {
      State.updateTask(pill, state as never);
      if (State.focusId == null || State.focusId === convPillId(conv)) State.setFocus(pill);
    }
    State.notify();
    return r.conv;
  }

  /** Port: a new conversation became current in ambxst-robo (New chat, a fresh drop). */
  fresh(conv: string) {
    // The caller already emptied the page (upstream's newChat): that is the new one's log.
    const page = State.chatHistory;
    const left = this.convs.get(this.conv);
    if (left && left.history === page && page.length === 0 && this.conv !== conv) this.convs.delete(this.conv);
    // A fresh drop (island.swallow) put its file in before resetting: it stays.
    const file = { droppedFile: State.droppedFile, promptContext: State.promptContext, dropInChat: State.dropInChat };
    this.adopt(conv, null, { applyModel: false });
    Object.assign(State, file);
    const c = this.cur();
    if (page.length === 0 && c.history.length === 0) {
      c.history = page;
      State.chatHistory = page;
    }
  }

  /** Polls ambxst-robo until conversation `conv`'s answer (begun before this island started) is in. */
  private watchPending(conv: string) {
    const poll = async () => {
      const c = this.convs.get(conv);
      if (!c || !c.sending) return;
      let list: CoreConv[];
      try {
        list = (await invoke<{ convs: CoreConv[] }>("chat_conversations", {})).convs ?? [];
      } catch {
        window.setTimeout(() => void poll(), 1500);
        return;
      }
      const x = list.find((y) => y.conv === conv);
      if (!x) {
        this.forget(conv);
        State.notify();
        return;
      }
      if (x.pending) {
        window.setTimeout(() => void poll(), 1500);
        return;
      }
      if (this.convs.get(conv) !== c) return;
      c.sending = false;
      c.stale = true;
      if (conv === this.conv) {
        try {
          const r = await invoke<CoreChat>("chat_current", {});
          if (r.conv === conv && this.convs.get(conv) === c) {
            c.history = rowsOf(r);
            c.stale = false;
            State.chatHistory = c.history;
            if (State.stateOverride === "thinking") State.stateOverride = null;
            this.reloaded();
          }
        } catch { /* stays stale: reloaded on its next switch */ }
      }
      this.finishPill(conv);
      State.notify();
    };
    window.setTimeout(() => void poll(), 1500);
  }

  /** Port (shell start): ambxst-robo's conversations come back, with their minis. */
  restore(r: CoreChat & { convs?: CoreConv[] }) {
    if (r.conv) {
      const c = this.convs.get("");
      if (c && !this.conv) {
        this.convs.delete("");
        this.convs.set(r.conv, c);
      }
    }
    for (const x of r.convs ?? []) {
      if (x.conv === r.conv) continue;
      const c = newConv([]);
      c.stale = true;
      c.sending = !!x.pending;
      c.title = x.title;
      c.key = x.key ? `${x.key.kind}:${x.key.id}` : null;
      Looks.noteKey(x.conv, c.key);
      this.convs.set(x.conv, c);
      this.pillFor(x.conv, c);
      if (x.pending) {
        State.updateTask(convPillId(x.conv), "thinking");
        this.watchPending(x.conv);
      }
    }
    if (r.conv) {
      this.adopt(r.conv, r);
      const me = r.convs?.find((x) => x.conv === r.conv);
      if (me) {
        const c = this.cur();
        c.title = me.title;
        c.key = me.key ? `${me.key.kind}:${me.key.id}` : null;
        Looks.noteKey(r.conv, c.key);
        const pill = this.pillFor(r.conv, c);
        if (me.pending) State.updateTask(convPillId(r.conv), "thinking");
        // The page's conversation is the one the mascot card shows.
        if (pill) State.setFocus(pill);
      }
    }
    void this.refreshConvs();
  }

  /** Port: the pill of the page's conversation, if it has one. */
  pagePill(): string | null {
    const id = convPillId(this.conv);
    return State.tasks.some((x) => x.id === id) ? id : null;
  }
}

/** Port: what this island keeps of one conversation. */
interface Conv {
  history: typeof State.chatHistory;
  sending: boolean;
  live: string | null;
  queued: Queued[];
  title: string;
  /** Its card in the chats column, "kind:id", once it has one. */
  key: string | null;
  /** ambxst-robo has newer turns than `history` (reload it when it comes on the page). */
  stale: boolean;
  /** Port: the message in flight was typed into the session's terminal (send). */
  terminal?: boolean;
  /** Port: when `live` last grew (performance.now()); 0 once a tool starts. */
  liveAt?: number;
  /** Port: deltas until then are core's flush before a tool, not talk. */
  hushUntil?: number;
  /** Port: tool calls started and not yet finished (PreToolUse − PostToolUse). */
  tools?: number;
}

/** Port: how long Robo keeps talking after the last streamed text (deltas come at ~15/s). */
const SPEAK_HOLD_MS = 700;
/** Port: core flushes the text's tail right after a tool call's PreToolUse. */
const SPEAK_HUSH_MS = 300;

function newConv(history: typeof State.chatHistory): Conv {
  return { history, sending: false, live: null, queued: [], title: "", key: null, stale: false };
}

/** A conversation pill (State task) and which conversation it is. */
export interface ConvTask { id: string; name: string; state: string; finalLine?: string | null; conv?: string; convKey?: string | null }

/** ambxst-robo's view of one conversation (chat_current / chat_switch / chat_open). */
export type CoreChat = {
  conv?: string;
  turns: { role: string; content: string }[];
  provider?: string;
  model?: string;
  pending?: string | null;
  current?: { kind: string; id: string } | null;
};

/** ambxst-robo's chat_conversations row. */
export type CoreConv = { conv: string; title: string; key: { kind: string; id: string } | null; pending: string | null; current: boolean };

/** The pill (and agent tag) of conversation `conv`. */
export function convPillId(conv: string): string {
  return `agent_${conv}`;
}

/** The chat's rows for `r`: its turns, then the message being answered, if any. */
export function rowsOf(r: CoreChat): typeof State.chatHistory {
  const rows = (r.turns ?? []).map((m, i) => ({
    id: 1_000_000 + nextId++ + i, role: m.role === "assistant" ? "assistant" : "user", content: m.content,
  }));
  if (r.pending) rows.push({ id: 1_000_000 + nextId++ + rows.length, role: "user", content: r.pending });
  return rows as typeof State.chatHistory;
}

/** A pill's name before ambxst-robo titles the chat: its first question. */
function titleOf(history: typeof State.chatHistory): string {
  const first = history.find((m) => m.role === "user")?.content ?? "";
  const line = first.replace(/\s+/g, " ").trim();
  return line.length > 40 ? `${line.slice(0, 39)}…` : line;
}

/** The provider and model a conversation last ran on, as a reopen applies. */
function applyModelOf(r: CoreChat) {
  let settings = State.settings;
  if (r.provider && r.provider !== settings.chatProvider) settings = { ...settings, chatProvider: r.provider as never };
  if (r.model) settings = withModel(settings, settings.chatProvider, r.model);
  if (settings !== State.settings) {
    State.settings = settings;
    void Bridge.saveSettings(State.settings);
  }
}

/**
 * Port: "Open terminal" on a session Robo's own chat runs (ambxst-robo's
 * `show-chat`): the island's home, where that chat is, its field focused.
 */
export function showChat() {
  if (!island) return;
  if (State.view !== "overview" && State.view !== "empty" && State.view !== "prompt" && !State.pendingApproval) {
    island.setView(State.defaultView());
  }
  window.setTimeout(() => {
    chat().focusViews();
  }, 160);
}

/**
 * Port (his ask): the header's new-conversation button — Ctrl+K's newChat
 * (island/shortcuts.ts) from any page: a fresh chat, on the chat page, its
 * field focused. Not while an answer is on its way (it would land in the new
 * chat), as Ctrl+K.
 */
export function newConversation(): boolean {
  // Port (multitasking): an answer on its way carries on in its own
  // conversation (its mini), so New chat is never refused.
  if (!island) return false;
  State.chatHistory = [];
  State.droppedFile = null;
  State.promptContext = null;
  void Bridge.chatReset();
  Sound.play("blip");
  island.setView("prompt");
  State.notify();
  window.setTimeout(() => chat().focusViews(), 160);
  return true;
}

let instance: Chat | null = null;

/** The app's one chat. */
export function chat(): Chat {
  if (!instance) {
    instance = new Chat();
    // Port: every "new chat" (the header's, upstream's Ctrl+K, a fresh drop)
    // is a new conversation in ambxst-robo; this island follows it there.
    const reset = async () => {
      try {
        const r = await invoke<{ conv?: string } | null>("chat_reset", {});
        if (r?.conv) chat().fresh(r.conv);
        else chat().reloaded();
      } catch {
        chat().reloaded();
      }
    };
    (Bridge as unknown as { chatReset: () => Promise<void> }).chatReset = reset;
  }
  return instance;
}
