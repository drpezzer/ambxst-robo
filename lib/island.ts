// The island without its web page: windows/src/island/island.ts with every DOM
// line taken out. The QML side (the Robo tab of Ambxst's notch, the bar's
// compact Robo) reads the geometry, the mascot's placement and glow from here each
// frame and draws them; everything else is the upstream logic, line for line.
//
// Differences from upstream, all forced by the host:
// - no wake strip / window collapse: Ambxst owns the windows (`host.mode()`).
// - views are QML: `host.viewCommand/viewTick/viewFocus` stand in for ViewHost.
// - the frame loop is a QML FrameAnimation: `host.wake()` starts it, `frame()`
//   returns whether it must keep running.

import { Tracked, Spring, clamp } from "@coucou/core/anim";
import { Bridge } from "@coucou/core/bridge";
import {
  EXPANDED_CORNER, EXPANDED_W, NOTCH_W, PANEL_W,
  ROUNDED_CORNER, VIEW_LAYOUTS, botGlowColor, botGlowOpacity, botPosition, chatPromptHeight,
  islandSize, QUESTION_PICKER_H,
  type BotEmoteName, type IslandMode, type IslandViewName,
} from "@coucou/core/layout";
import { Sound } from "@coucou/core/sound";
import { State } from "@coucou/core/state";
import { SPOTIFY_ID, islandDances } from "@coucou/core/spotify";
import { Robot } from "./robot/mascot";
import * as Robo from "./robot/config";
import * as Compaction from "./compaction";
import * as Looks from "./looks";
import * as PersonalOnly from "./personal-only";
import * as AmbxstMascot from "./ambxst/engine";
import { chat } from "./views/chat";
import { BotEngine, hexToRGB } from "@coucou/mascot/engine";
import { Greeting } from "@coucou/mascot/greeting";
import { SeasonCache, parseOutfit } from "@coucou/mascot/wardrobe";
import { USC, UploadSeq } from "@coucou/upload/sequence";
import { closePlanCard, openPlanColor, planCardOpen } from "@coucou/views/usage";
import { IslandStateMachine } from "@coucou/island/fsm";
import { greetingPose, ASP as GREETING_ASP } from "@coucou/mascot/greeting";
import { refreshHookPills } from "@coucou/island/integrations";
import { DesktopLink } from "@coucou/island/desktop";
import type { ViewCommand } from "@coucou/island/shortcuts";
import { DRAG_THRESHOLD } from "@coucou/mascot/desktop-logic";
import { HELPER_BADGE, miniBotsBusy, syncMiniBotStates, tickMiniBots } from "./minibots";
import { glowColor } from "./palette";


export const BOT_OVERHANG = 40;
const CLAUDE_DESKTOP_ID = "agent_claude-desktop";
/** Port: the question card's "Other…" field row (29 px + the stack's 5 px gap). */
const QUESTION_OTHER_ROW_H = 34;
/** Extra canvas on each side of the mascot, for the witch hat's brim and the Santa hat's tip. */
export const BOT_SIDE = 24;
/** Port (his ask): Robo sleeps after this long idle (s), unless the pointer is this close (px). */
const ROBO_SLEEP_AFTER = 120;
const ROBO_SLEEP_NEAR = 150;
/** Robo's antenna, collar to bulb top, in head units (tv/geometry HEAD: 0.028 + stem 0.2 + bulb). */
const ANTENNA_UNITS = 0.028 + 0.2 + 0.052 * 2;
/** Same margin as the Rust hit test (src-tauri/src/island.rs). */
const HIT_MARGIN = 14;

const UPLOAD_VIEWS: ReadonlySet<IslandViewName> = new Set(["upload", "uploading", "choose"]);
const PRE_PROGRESS = USC.T_PROG_START - USC.T_DROP;
const modeOrder = (m: IslandMode) => (m === "hidden" ? 0 : m === "compact" ? 1 : 2);

/** What the QML side provides. */
export interface IslandHost {
  /** Start the frame loop (FrameAnimation) if it is not running. */
  wake(): void;
  /** The island's mode changed (hidden/compact/expanded): open/close the notch. */
  modeChanged(mode: IslandMode, prev: IslandMode): void;
  /** Keyboard to the island (chat) or back. */
  focus(on: boolean): void;
  viewCommand(view: IslandViewName, command: ViewCommand): void;
  /** True while the view on screen animates (ticker scroll). */
  viewTick(view: IslandViewName, nowMs: number): boolean;
  viewFocus(view: IslandViewName): void;
}

export interface ViewActions {
  setView(v: IslandViewName): void;
  cancelDrop(): void;
  collapse(): void;
  foldApproval(): void;
  setFocus(id: string): void;
  openTerminal(): void;
  openTarget(): void;
  openUrl(url: string): void;
  decide(d: "allow" | "deny"): void;
  answer(answers: Record<string, string | string[]>): void;
  answerInTerminal(): void;
  toggleSound(): void;
  setVolume(v: number): void;
  setAutoClose(s: number): void;
  openSettingsWindow(): void;
  blip(): void;
  chooseOutfit(selection: string): void;
  previewOutfit(outfit: string | null): void;
  askAboutDrop(): void;
}

export class Island {
  readonly fsm = new IslandStateMachine();
  readonly desktop: DesktopLink;
  readonly actions: ViewActions;

  width = new Tracked(NOTCH_W);
  height = new Tracked(0);
  radius = new Tracked(ROUNDED_CORNER);
  botCx = new Spring(46);
  botCy = new Spring(16);
  botSize = new Spring(10);

  readonly engine = new BotEngine();
  /** Port: the badge colour while a helper is focused (see prepareBot), else upstream's. */
  private helperBadge: ReturnType<typeof hexToRGB> | null = null;
  private readonly badgeHook = (() => {
    const e = this.engine as unknown as { drawBadge: (x: unknown, b: { color: unknown }, ...r: unknown[]) => void };
    const draw = e.drawBadge.bind(this.engine);
    e.drawBadge = (x, b, ...r) => draw(x, this.helperBadge ? { ...b, color: this.helperBadge } : b, ...r);
    return true;
  })();
  readonly greeting = new Greeting();
  private greetingShown = false;
  private seasons = new SeasonCache();

  running = false;
  private lastFrame = 0;
  dirty = true;

  wasInIsland = false;

  private botHovering = false;
  private botHoverTimer: number | null = null;
  private lastLoveTime = 0;
  private botHoverStart = { x: 0, y: 0 };

  private confusedRecovery: number | null = null;
  private prevViewBeforeConfused: IslandViewName = "overview";
  private lastSyncedView: IslandViewName | null = null;

  onGreetingDone: (() => void) | null = null;
  onWake: (() => void) | null = null;

  private botPress: { x: number; y: number } | null = null;
  private silentReveal = false;
  private uploadTens = 0;
  private uploadDone = false;

  // ── What QML reads each frame ───────────────────────────────────────────────
  /** The mascot's canvas: left/top in island coordinates, size, opacity. */
  bot = { left: 0, top: 0, w: 0, h: 0, size: 0, visible: false };
  /** Glow behind the mascot: null when hidden. */
  glow: { x: number; y: number; d: number; color: string; opacity: number } | null = null;
  /** Countdown bar width (px, 0 = hidden). */
  countdownW = 0;
  /** The mini grid's place (compact island). */
  miniGrid = { left: 0, top: 0, visible: false };
  /** Content layer state. */
  content = { opacity: 0, interactive: false, headerInteractive: false };
  greetingActive = false;

  constructor(private host: IslandHost) {
    this.desktop = new DesktopLink({
      reveal: () => this.reveal(),
      wardrobeFromDesktop: () => this.wardrobeFromDesktop(),
      // His ask: three pokes on the desktop make the mascot dizzy where he is,
      // without opening the island on the confused card as upstream does.
      dizzyFromDesktop: () => this.handleDizzy(true),
    });
    this.actions = this.buildActions();
    this.wireFsm();
    this.engine.onDizzy = () => this.handleDizzy();
    this.greeting.onComplete = () => {
      // Port: a greeting the tab started (his first open of it) ends on the
      // open island's home, not by folding it away.
      if (this.greetInTab) {
        this.greetInTab = false;
        // The mascot carries on from where the greeting leaves him (its 640×150
        // space is the island's own), instead of springing up from his
        // compact spot: centre, and a box his body fits as the greeting's.
        const p = greetingPose(this.greeting.elapsed);
        if (p.hb > 1) {
          this.botCx.set(p.x);
          this.botCy.set(p.y);
          this.botSize.set((p.hb * GREETING_ASP) / 0.6);
        }
        this.fsm.forceHome();
        this.setView(State.defaultView());
        this.onGreetingDone?.();
        return;
      }
      this.fsm.greetComplete();
      this.onGreetingDone?.();
    };
    State.subscribe(() => {
      this.dirty = true;
      this.ensureRunning();
    });
  }

  private closeApproval() {
    State.endApproval();
    this.fsm.pinned = false;
    this.setView(State.defaultView());
  }

  foldApproval() {
    if (!State.pendingApproval || State.mode !== "expanded") return;
    State.isPinned = true;
    this.fsm.pinned = true;
    this.fsm.forcePetit();
  }

  private buildActions(): ViewActions {
    return {
      setView: (v) => this.setView(v),
      cancelDrop: () => this.discardDrop(),
      collapse: () => this.collapse(),
      foldApproval: () => this.foldApproval(),
      setFocus: (id) => {
        State.setFocus(id);
        Sound.play("blip");
        const req = State.pendingApproval;
        if (req?.pillId === id) this.setView(req.questions ? "question" : "approval");
      },
      openTerminal: () => {
        const task = State.focusTask;
        if (task?.id === CLAUDE_DESKTOP_ID) void Bridge.openClaudeDesktop();
        else void Bridge.openSession(task?.sessionId ?? null, task?.sessionCwd ?? null);
        // Port (his call): the notch closes, so the terminal just opened has
        // the screen (and the chat isn't typed into alongside it).
        this.collapse();
      },
      openTarget: () => {
        const task = State.focusTask;
        if (!task) return;
        const urls: Record<string, string> = {
          integration_resend: "https://resend.com/emails",
          integration_vercel: "https://vercel.com/dashboard",
          integration_github: "https://github.com/pulls",
          integration_stripe: "https://dashboard.stripe.com/payments",
          integration_notion: "https://notion.so",
          integration_calcom: "https://app.cal.com/bookings",
        };
        if (task.id === CLAUDE_DESKTOP_ID) void Bridge.openClaudeDesktop();
        else if (task.id === "integration_claude" || task.sessionId) {
          void Bridge.openSession(task.sessionId ?? null, task.sessionCwd ?? null);
          this.collapse(); // port: as openTerminal
        } else if (task.id === "integration_n8n") void Bridge.openN8n();
        else if (task.id === SPOTIFY_ID) void Bridge.spotifyOpen();
        else if (urls[task.id]) void Bridge.openUrl(urls[task.id]);
      },
      openUrl: (url) => {
        if (url) void Bridge.openUrl(url);
      },
      decide: (d) => {
        const req = State.pendingApproval;
        void Bridge.log(`decide ${d} req=${req?.requestId ?? "none"}`);
        if (!req) return;
        Sound.play(d === "deny" ? "blip" : "approve");
        void Bridge.approvalDecision(req.requestId, d);
        this.closeApproval();
      },
      answer: (answers) => {
        const req = State.pendingApproval;
        if (!req) return;
        Sound.play("approve");
        void Bridge.approvalAnswer(req.requestId, answers);
        this.closeApproval();
      },
      answerInTerminal: () => {
        const req = State.pendingApproval;
        if (!req) return;
        Sound.play("blip");
        void Bridge.approvalDecline(req.requestId);
        this.closeApproval();
      },
      toggleSound: () => {
        State.settings.soundEnabled = !State.settings.soundEnabled;
        Sound.setEnabled(State.settings.soundEnabled);
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      setVolume: (v) => {
        State.settings.soundVolume = v;
        Sound.setVolume(v);
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      setAutoClose: (s) => {
        State.settings.autoCloseInterval = s;
        this.fsm.homeToPetitDelay = s;
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      openSettingsWindow: () => void Bridge.openSettingsWindow(),
      blip: () => Sound.play("blip"),
      chooseOutfit: (selection) => {
        // Port (his ask): the wardrobe dresses the chat in front only.
        const conv = Looks.frontConv();
        if (conv) {
          if (Looks.outfitOf(conv) === selection) return;
          Looks.edit(conv, (l) => { l.coucou.outfit = selection; });
          Sound.play("pop");
          this.engine.triggerEmote("proud");
          return;
        }
        if (parseOutfit(State.settings.mascotOutfit) === selection) return;
        State.settings.mascotOutfit = selection;
        void Bridge.saveSettings(State.settings);
        Sound.play("pop");
        this.engine.triggerEmote("proud");
        State.notify();
      },
      previewOutfit: (outfit) => {
        State.wardrobePreview = outfit as never;
        State.notify();
      },
      // UploadCanvas's `ask` callback (island.ts build()).
      askAboutDrop: () => {
        // Port (his ask): attached, so no longer offered as the working directory.
        chat().dropSettled();
        State.promptContext = State.droppedFile
          ? { kind: "file", name: State.droppedFile.name, path: State.droppedFile.path }
          : null;
        this.setView("prompt");
      },
    };
  }

  // ── FSM ─────────────────────────────────────────────────────────────────────

  private wireFsm() {
    this.fsm.homeToPetitDelay = State.settings.autoCloseInterval;
    this.fsm.openOnHover = State.settings.openOnHover;
    this.fsm.onTransition = (from, to) => {
      if (from === "coucou" && to !== "coucou") this.desktop.launch();
      switch (to) {
        case "hidden":
          this.setMode("hidden");
          break;
        case "petit":
          if (from === "coucou") this.greeting.interrupt();
          else if (from === "hidden" && !this.silentReveal) Sound.play("peek");
          this.setMode("compact");
          if (from === "coucou") State.view = State.defaultView();
          if (!this.wasInIsland) this.fsm.mouseLeft();
          break;
        case "home":
          this.expand(State.defaultView());
          if (!this.wasInIsland) this.fsm.mouseLeft();
          void refreshHookPills();
          break;
        case "coucou":
          this.expand("greeting");
          this.greeting.start();
          break;
      }
      State.notify();
      if (from === "hidden") this.onWake?.();
    };
  }

  /** Port: the launch greeting, played when he first opens the Robo tab. */
  private greetInTab = false;
  launchInTab() {
    this.greetInTab = true;
    this.launch();
  }

  launch() {
    this.fsm.launch();
  }

  // ── Mode / view ─────────────────────────────────────────────────────────────

  private setMode(mode: IslandMode) {
    const prev = State.mode;
    if (mode === prev) return;
    State.mode = mode;
    if (mode === "expanded") Sound.play("open");
    if (prev === "expanded") {
      Sound.play("close");
      if (!State.pendingApproval) State.isPinned = false;
      void Bridge.focusWindow(false);
    }
    if (mode !== "expanded") {
      closePlanCard();
      this.engine.resetMorph();
      UploadSeq.deactivate();
    }
    this.animateGeometry(modeOrder(mode) < modeOrder(prev));
    this.host.modeChanged(mode, prev);
    State.notify();
  }

  get uploadActive(): boolean {
    return State.mode === "expanded" && UploadSeq.isActive && UPLOAD_VIEWS.has(State.view);
  }

  private stopSequenceIfLeaving(view: IslandViewName) {
    if (UploadSeq.isActive && !UPLOAD_VIEWS.has(view)) UploadSeq.deactivate();
  }

  expand(view: IslandViewName) {
    this.stopSequenceIfLeaving(view);
    if (view !== "overview") closePlanCard();
    State.view = view;
    if (State.mode !== "expanded") this.setMode("expanded");
    else this.animateGeometry(false);
    State.lastActivity = performance.now();
    State.notify();
  }

  /**
   * Port (his ask): with the notch open on the chat or home page, a finished
   * turn is already in sight there: no "Open terminal / OK" card over it
   * (its OK closed the notch). The pill still says it's done.
   */
  private finishedInSight(view: IslandViewName): boolean {
    return view === "finished" && State.mode === "expanded"
      && (State.view === "prompt" || State.view === "overview" || State.view === "empty");
  }

  setView(view: IslandViewName) {
    if (this.finishedInSight(view)) return;
    this.frontChat(view);
    this.stopSequenceIfLeaving(view);
    if (view !== "overview") closePlanCard();
    if (State.mode !== "expanded") {
      this.fsm.forceHome();
      State.view = view;
      this.animateGeometry(false);
      State.notify();
      return;
    }
    const grew = VIEW_LAYOUTS[view].height >= VIEW_LAYOUTS[State.view].height;
    State.view = view;
    State.lastActivity = performance.now();
    this.animateGeometry(!grew);
    State.notify();
  }

  collapse() {
    if (State.pendingApproval) {
      this.foldApproval();
      return;
    }
    State.isPinned = false;
    this.fsm.pinned = false;
    this.fsm.forcePetit();
  }

  /**
   * His ask: the chat page is that chat's: its mini comes to the front
   * (another pill clicked before, GitHub's say, stayed there).
   */
  private frontChat(view: IslandViewName) {
    if (view !== "prompt" || State.pendingApproval) return;
    const pill = `agent_${chat().conv}`;
    if (chat().conv && State.tasks.some((t) => t.id === pill) && State.focusId !== pill) State.setFocus(pill);
  }

  alert(view: IslandViewName) {
    if (this.finishedInSight(view)) return;
    this.frontChat(view);
    this.fsm.pinned = State.isPinned;
    this.fsm.forceHome();
    this.expand(view);
  }

  reveal() {
    this.fsm.reveal();
  }

  revealSilently() {
    this.silentReveal = true;
    this.fsm.reveal();
    this.silentReveal = false;
  }

  toggleWardrobe() {
    // His ask: the wardrobe is the Coucou mascot's alone.
    if (!Robo.hasWardrobe()) return;
    if (State.paused || State.mode === "hidden") return;
    if (State.mode === "expanded" && (State.view === "greeting" || this.uploadActive)) return;
    if (State.mode === "expanded" && State.view === "wardrobe") this.setView(State.defaultView());
    else this.setView("wardrobe");
  }

  wardrobeFromDesktop() {
    this.wardrobeAnywhere();
  }

  wardrobeAnywhere() {
    if (State.mode === "expanded" && State.view === "wardrobe") {
      this.setView(State.defaultView());
      return;
    }
    if (State.paused || !Robo.hasWardrobe()) return;
    this.alert("wardrobe");
  }

  dropPin() {
    this.fsm.pinned = false;
    if (!this.wasInIsland) this.fsm.mouseLeft();
  }

  emote(name: BotEmoteName) {
    this.engine.triggerEmote(name);
    this.ensureRunning();
  }

  setPinned(on: boolean) {
    State.isPinned = on;
    this.fsm.pinned = on;
    if (on) {
      this.fsm.cancelTimers();
    } else if (!this.wasInIsland && this.fsm.state === "home") {
      this.fsm.mouseLeft();
    }
    State.notify();
  }

  takeKeyboard() {
    void Bridge.focusWindow(true);
  }

  canLeaveIsland(): boolean {
    return this.desktop.supported;
  }

  flyOutOrHome() {
    const busy = State.mode === "expanded" && (State.view === "greeting" || this.uploadActive);
    if (busy && !State.mascotOnDesktop) return;
    this.desktop.flyOutOrHome();
  }

  viewCommand(command: ViewCommand) {
    this.host.viewCommand(State.view, command);
  }

  // ── File drop ───────────────────────────────────────────────────────────────

  onDragDrop(e: { type: string; paths?: string[] }) {
    if (e.type !== "over") void Bridge.log(`drag ${e.type} ${e.paths?.length ?? 0} file(s)`);
    if (State.paused) return;
    switch (e.type) {
      // Port (his ask): there is no separate drop page. A file dragged over
      // Robo brings up the chat page, which shows the drop itself (its
      // field gives way to a dotted border, ChatPanel) while the mascot opens up.
      case "enter":
      case "over": {
        if (State.fileDragOver) return;
        State.fileDragOver = true;
        this.engine.animateMorph(1);
        // Port (his ask): an island already open just turns to the chat page:
        // alert()'s forceHome went by the default view first (a second
        // layout, the mascot's springs restarted) for nothing.
        if (State.mode === "expanded") {
          if (State.view !== "prompt") this.setView("prompt");
        } else {
          this.alert("prompt");
        }
        // A drag is a hover the island never hears of (no pointer events
        // while it lasts, nor through the notch's own DropArea): the
        // auto-close countdown the pointer started when it went to fetch the
        // file must not fold the notch under it.
        this.fsm.cancelTimers();
        State.notify();
        break;
      }
      case "leave": {
        if (!State.fileDragOver) return;
        State.fileDragOver = false;
        this.engine.animateMorph(0);
        // The drag went away: the auto-close counts again from here.
        if (!this.wasInIsland && State.mode === "expanded") this.fsm.mouseLeft();
        State.notify();
        break;
      }
      case "drop": {
        State.fileDragOver = false;
        const path = e.paths?.[0];
        if (!path) {
          this.engine.animateMorph(0);
          State.notify();
          return;
        }
        // Port (his ask): a folder may become the working directory instead.
        chat().dropped(path);
        // An ongoing conversation takes the file as an attachment to the next
        // message; a fresh one gets the usual eat / load / "ask about it?".
        if (State.chatHistory.length > 0) this.swallowIntoChat(path);
        else {
          UploadSeq.enterZone(State.mouseInIsland.x, State.mouseInIsland.y);
          this.swallow(path);
        }
        break;
      }
    }
  }

  private swallow(path: string) {
    const name = path.split(/[\\/]/).pop() || "file";
    State.droppedFile = { name, path };
    State.promptContext = { kind: "file", name, path };
    State.dropInChat = false;
    State.chatHistory = [];
    // (Kept: a folder too big to attach notes so in this fresh chat, once it is ambxst-robo's.)
    const reset = Promise.resolve(Bridge.chatReset());

    UploadSeq.performDrop(State.uploadDuration);
    this.uploadTens = 0;
    this.uploadDone = false;

    this.engine.gulp();
    Sound.play("approve");
    this.engine.triggerEmote("happy");
    this.engine.animateMorph(0);

    State.uploadProgress = 0;
    this.setView("uploading");
    this.ensureRunning();

    void Bridge.ingestFile(path)
      .then((file) => {
        if (State.droppedFile?.path !== path) return;
        State.droppedFile = { name: file.name, path: file.path };
        State.promptContext = { kind: "file", name: file.name, path: file.path };
        State.notify();
      })
      .catch((err) => {
        if (State.droppedFile?.path !== path) return;
        UploadSeq.deactivate();
        const message = String(err).replace(/^Error:\s*/, "");
        // Port (his ask): a folder too big to attach becomes the working
        // directory instead, without asking; a note in the chat says so.
        if (chat().folderTooBig(message)) {
          State.droppedFile = null;
          State.promptContext = null;
          this.engine.animateMorph(0);
          this.setView("prompt");
          void chat().folderAsWorkDir(path, reset);
          return;
        }
        State.noteMessage = message;
        this.engine.animateMorph(0);
        this.setView("note");
        Sound.play("error");
        // Port (his ask): a folder too big to copy may still be the working
        // directory: the chat page offers it after the note.
        const offer = chat().dropFailed(path);
        if (offer) {
          State.droppedFile = null;
          State.promptContext = null;
        }
        window.setTimeout(() => this.setView(offer ? "prompt" : State.defaultView()), 2400);
      });
  }

  /**
   * Port (his ask): a file dropped into an ongoing conversation. The mascot eats it
   * where he is (gulp, the happy look); it is attached to the chat's next
   * message (the chip over the field), which the user can send as is or with
   * words of their own.
   */
  private swallowIntoChat(path: string) {
    const name = path.split(/[\\/]/).pop() || "file";
    // Robo: the slot shuts on it, a happy little hop.
    this.robot?.sim.react("happy", 1.2);
    State.droppedFile = { name, path };
    State.promptContext = { kind: "file", name, path };
    // Its chip sits by the field (ChatPanel), not atop the log.
    State.dropInChat = true;
    this.engine.gulp();
    Sound.play("approve");
    this.engine.triggerEmote("happy");
    this.engine.animateMorph(0);
    State.notify();
    this.ensureRunning();
    void Bridge.ingestFile(path)
      .then((file) => {
        if (State.droppedFile?.path !== path) return;
        State.droppedFile = { name: file.name, path: file.path };
        State.promptContext = { kind: "file", name: file.name, path: file.path };
        State.notify();
      })
      .catch((err) => {
        if (State.droppedFile?.path !== path) return;
        State.droppedFile = null;
        State.promptContext = null;
        const message = String(err).replace(/^Error:\s*/, "");
        // Port (his ask): a folder too big to attach becomes the working directory (a note says so).
        if (chat().folderTooBig(message)) {
          State.notify();
          void chat().folderAsWorkDir(path);
          return;
        }
        chat().dropFailed(path);
        State.noteMessage = message;
        this.setView("note");
        Sound.play("error");
        window.setTimeout(() => this.setView("prompt"), 2400);
      });
  }

  discardDrop() {
    chat().dropSettled();
    State.droppedFile = null;
    State.promptContext = null;
    this.setView(State.defaultView());
  }

  private stepSequence() {
    const since = UploadSeq.sinceDrop();
    if (since == null) return;
    const dur = State.uploadDuration;
    const p = Math.max(0, Math.min(1, (since - PRE_PROGRESS) / dur));
    const tens = Math.floor(p * 10);
    if (tens > this.uploadTens && tens < 10) {
      this.uploadTens = tens;
      Sound.play("tick");
    }
    if (!this.uploadDone && since >= PRE_PROGRESS + dur) {
      this.uploadDone = true;
      Sound.play("approve");
      this.engine.triggerEmote("happy");
    }
    if (since >= PRE_PROGRESS + dur + 1 && State.view === "uploading") {
      this.setView("choose");
    }
  }

  // ── Geometry ────────────────────────────────────────────────────────────────

  targetSize(): { w: number; h: number; r: number } {
    let { w, h } = islandSize(State.mode, State.view, State.chatHistory.length);
    if (State.mode === "expanded" && State.view === "question" && State.pendingApproval?.questions) {
      // Port: + the "Other…" answer row under the options (QuestionView.qml).
      h = QUESTION_PICKER_H + QUESTION_OTHER_ROW_H;
    }
    // Port (his ask): in the Robo tab the chat page fills the tab's whole
    // height (upstream sizes it to its messages, up to 300).
    if (State.mode === "expanded" && State.view === "prompt" && this.chatFillHeight > 0) h = this.chatFillHeight;
    // Port (his ask): the compact "finished" popup grows over hover to show
    // the whole answer (FinishedView.qml).
    if (State.mode === "expanded" && State.view === "finished" && this.finishedHeight > 0) h = this.finishedHeight;
    const r = State.mode === "expanded" ? EXPANDED_CORNER : ROUNDED_CORNER;
    return { w, h, r };
  }

  /** Port: the height the chat page fills (the tab's content area, RoboTab); 0 = upstream's. */
  chatFillHeight = 344;

  /** Port: the finished popup's grown height (FinishedView.qml); 0 = upstream's 160. */
  finishedHeight = 0;
  setFinishedHeight(h: number) {
    const next = Math.max(0, Math.round(h));
    if (next === this.finishedHeight) return;
    const before = this.targetSize().h;
    this.finishedHeight = next;
    if (State.mode === "expanded" && State.view === "finished") this.animateGeometry(this.targetSize().h < before);
    this.ensureRunning();
  }

  /** The island grew (spring) or shrank (curve): the notch follows the same motion. */
  lastMotion: "spring" | "curve" = "spring";

  private animateGeometry(shrinking: boolean) {
    // Port: the held height is only the finished popup's (holdHeight).
    if (this.heightHeld && !(State.mode === "expanded" && State.view === "finished")) this.heightHeld = false;
    const { w, h, r } = this.targetSize();
    this.lastMotion = shrinking ? "curve" : "spring";
    if (shrinking) {
      this.width.curveTowards(w);
      if (!this.heightHeld) this.height.curveTowards(h);
      this.radius.curveTowards(r);
    } else {
      this.width.springTo(w);
      if (!this.heightHeld) this.height.springTo(h);
      this.radius.springTo(r);
    }
    this.ensureRunning();
  }

  /**
   * Port: the compact finished popup moves the island's height itself, on the
   * notch's own curve (FinishedView.qml), so the two grow and shrink as one:
   * the island's spring and the notch's animation never matched. Held, the
   * island's own animations leave the height alone.
   */
  heightHeld = false;
  holdHeight(target: number) {
    this.finishedHeight = Math.round(target);
    this.heightHeld = true;
  }
  jumpHeight(v: number) {
    this.height.jump(v);
    this.ensureRunning();
  }
  releaseHeight(finishedHeight: number) {
    this.heightHeld = false;
    this.finishedHeight = Math.max(0, Math.round(finishedHeight));
  }

  /** Island rect in panel coordinates (origin top-left of the 720-wide panel). */
  islandRect(): { x: number; y: number; w: number; h: number } {
    const w = this.width.value;
    const hh = this.height.value;
    return { x: (PANEL_W - w) / 2, y: 0, w, h: hh };
  }

  // ── Input (QML forwards pointer events in island coordinates) ───────────────

  /** mousedown inside the island at (x, y) island coordinates (upstream wireInput). */
  /**
   * Port (his ask): set by the shell while the notch shows just the island
   * (an alert Robo raised itself): a click on the mascot opens the whole tab
   * instead of slapping him. A drag still carries him out.
   */
  botClickOpens: (() => void) | null = null;

  pointerDown(x: number, y: number, button: "left" | "right") {
    const r = this.islandRect();
    const px = x + r.x, py = y + r.y;
    Sound.resume();
    State.lastActivity = performance.now();
    this.fsm.userInteracted();
    // Port: upstream's loop is already up from the mousemoves before any click;
    // a press on a still pointer brings no move here (the slap must play).
    this.ensureRunning();
    if (button === "left" && this.isBotHit(px, py)) this.botPress = { x: px, y: py };
    if (button === "right" && this.isBotHit(px, py)) {
      this.cancelBotHover();
      this.toggleWardrobe();
      return;
    }
    if (State.mode !== "expanded") {
      this.fsm.click();
      return;
    }
    if (this.isBotHit(px, py)) {
      this.cancelBotHover();
      // Opens on release instead (pointerUp), unless it turns into a drag.
      if (this.botClickOpens) return;
      const wasDizzy = this.engine.state === "dizzy";
      this.engine.slap();
      // Robo: a click bounces him; the third (the mascot goes dizzy) spins him
      // with the error face, both at once. Clicks while dizzy do nothing.
      this.roboAwakeAt = performance.now();
      if (this.robot && !wasDizzy) {
        if (this.engine.state === "dizzy") this.robot.dizzy();
        else this.robot.click();
      }
    }
  }

  /** True when a press on the mascot turned into a drag out to the desktop. */
  pointerMove(x: number, y: number, leftDown: boolean): boolean {
    const r = this.islandRect();
    const px = x + r.x, py = y + r.y;
    if (this.desktop.carrying) {
      this.desktop.carry(px, py);
      return true;
    }
    const press = this.botPress;
    if (!press) return false;
    if (!leftDown) {
      this.botPress = null;
      return false;
    }
    if (Math.hypot(px - press.x, py - press.y) <= DRAG_THRESHOLD) return false;
    this.botPress = null;
    if (!this.canDragOut()) return false;
    this.cancelBotHover();
    this.desktop.pickUp(px, py);
    return true;
  }

  pointerUp(x: number, y: number) {
    const r = this.islandRect();
    // A press on the mascot that never became a drag (pointerMove clears it then).
    const clicked = this.botPress !== null && State.mode === "expanded";
    this.botPress = null;
    if (this.desktop.carrying) {
      this.desktop.carryEnd(x + r.x, y + r.y);
      return;
    }
    if (clicked && this.botClickOpens) {
      Sound.play("blip");
      this.botClickOpens();
    }
  }

  /** Escape typed into the island. */
  escape() {
    if (State.mode === "expanded") {
      if (State.pendingApproval) this.foldApproval();
      else if (!State.isPinned) this.collapse();
    }
    State.lastActivity = performance.now();
  }

  /** Cursor in panel coordinates; (-10000, -10000) when the pointer left. */
  onCursor(x: number, y: number) {
    State.mouse = { x, y };
    const rect = this.islandRect();
    State.mouseInIsland = { x: x - rect.x, y: y - rect.y };
    if (State.fileDragOver) this.ensureRunning();

    if (UploadSeq.isActive && !UploadSeq.dropped) {
      UploadSeq.updateCursor(State.mouseInIsland.x, State.mouseInIsland.y);
    }

    // Port: the tab's extras (home chat, chats column) are part of the open
    // island for the auto-close, as everything Coucou shows is upstream.
    // Port: a greeting the tab started ignores the pointer: in the coucou state
    // upstream folds the island the moment the pointer is off it, which (the
    // island small and centred in the tab) closed the notch at the start or
    // the end of the greeting.
    const inIsland = this.greetInTab || this.extraHover ||
      (x >= rect.x - HIT_MARGIN && x <= rect.x + rect.w + HIT_MARGIN &&
      y >= rect.y - HIT_MARGIN && y <= rect.y + rect.h + HIT_MARGIN);

    const wasIn = this.wasInIsland;
    this.wasInIsland = inIsland;
    if (inIsland && !wasIn) {
      if (this.fsm.state === "coucou") this.greeting.hover();
      this.fsm.mouseEntered();
    }
    if (!inIsland && wasIn) {
      this.fsm.mouseLeft();
    }

    const overBot = State.mode === "expanded" && State.stateOverride == null && this.isBotHit(x, y);
    if (overBot && !this.botHovering) this.botHoverIn(x, y);
    if (!overBot && this.botHovering) this.cancelBotHover();
    this.botHovering = overBot;
    if (this.botHovering) {
      const d = Math.hypot(x - this.botHoverStart.x, y - this.botHoverStart.y);
      if (d > 40) {
        this.botHoverStart = { x, y };
        this.scheduleLove();
      }
    }

    this.ensureRunning();
  }

  /** Port: the pointer is over the tab's extras (they keep the island open, as hovering it does). */
  private extraHover = false;
  setExtraHover(on: boolean) {
    if (this.extraHover === on) return;
    this.extraHover = on;
    this.onCursor(State.mouse.x, State.mouse.y);
  }

  /** Port: typing in one of Robo's fields with the pointer away starts the auto-close again. */
  typingActivity() {
    if (!this.wasInIsland) this.fsm.homeToPetitDelay = this.fsm.homeToPetitDelay;
  }

  /** The pointer is on the island as the compositor sees it (Hyprland: hover of the notch). */
  setPointerInside(inside: boolean) {
    if (!inside) this.onCursor(-10_000, -10_000);
  }

  private canDragOut(): boolean {
    if (State.mode === "hidden" || !this.desktop.canPickUp()) return false;
    return !(State.mode === "expanded" && (State.view === "greeting" || this.uploadActive));
  }

  isBotHit(x: number, y: number): boolean {
    if (State.mascotOnDesktop) return false;
    const rect = this.islandRect();
    const cx = rect.x + this.botCx.value;
    const cy = rect.y + this.botCy.value;
    const radius = this.botSize.value / 2;
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius;
  }

  private botHoverIn(x: number, y: number) {
    if (performance.now() / 1000 - this.lastLoveTime < 6) return;
    this.botHoverStart = { x, y };
    this.engine.blink();
    this.engine.tgEs = 1.08;
    Sound.play("hover");
    this.scheduleLove();
  }

  private scheduleLove() {
    if (this.botHoverTimer != null) window.clearTimeout(this.botHoverTimer);
    this.botHoverTimer = window.setTimeout(() => {
      this.botHoverTimer = null;
      if (!this.botHovering || State.stateOverride != null) return;
      if (performance.now() / 1000 - this.lastLoveTime < 6) return;
      this.lastLoveTime = performance.now() / 1000;
      this.engine.triggerEmote("love");
      Sound.play("love");
      this.robot?.love();
    }, 1900);
  }

  private cancelBotHover() {
    if (this.botHoverTimer != null) window.clearTimeout(this.botHoverTimer);
    this.botHoverTimer = null;
    this.engine.tgEs = 1;
  }

  /** Port (his bug): until when Robo shows the error face, whatever else changes the state. */
  private dizzyUntil = 0;

  handleDizzy(quiet = false) {
    this.dizzyUntil = performance.now() + 3300;
    this.prevViewBeforeConfused = State.view;
    State.stateOverride = "dizzy";
    this.engine.setState("dizzy");
    Sound.play("dizzy");
    if (!quiet) this.alert("confused");
    else State.notify();
    if (this.confusedRecovery != null) window.clearTimeout(this.confusedRecovery);
    this.confusedRecovery = window.setTimeout(() => {
      this.confusedRecovery = null;
      State.stateOverride = null;
      this.engine.setState(State.effectiveState);
      if (State.view === "confused") {
        const fallback = State.defaultView();
        this.setView(this.prevViewBeforeConfused === "confused" ? fallback : this.prevViewBeforeConfused);
      }
      this.engine.triggerEmote("happy");
      State.notify();
    }, 3300);
  }

  // ── Frame loop ──────────────────────────────────────────────────────────────

  ensureRunning() {
    if (this.running) return;
    this.running = true;
    this.lastFrame = performance.now();
    this.host.wake();
  }

  /**
   * One frame: steps everything upstream's frame() steps, except drawing,
   * which QML does right after (drawBot / greeting.draw / upload canvas).
   * Returns false when the loop may stop.
   */
  frame(nowMs: number): boolean {
    const dt = Math.min(0.05, (nowMs - this.lastFrame) / 1000);
    this.lastFrame = nowMs;
    this.lastDt = dt;

    this.width.step(dt, nowMs);
    this.height.step(dt, nowMs);
    this.radius.step(dt, nowMs);

    if (this.dirty) {
      this.dirty = false;
      this.sync();
    }

    this.updateBotTargets();
    this.botCx.step(dt);
    this.botCy.step(dt);
    this.botSize.step(dt);
    this.placeBot();

    const greetingActive = State.mode === "expanded" && State.view === "greeting";
    this.greetingActive = greetingActive;
    // Upstream draws the greeting instead of the mascot while it plays.
    if (!greetingActive) this.prepareBot(dt);

    tickMiniBots(dt);
    const viewAnimating = this.host.viewTick(State.view, nowMs) === true;
    if (UploadSeq.isActive) this.stepSequence();
    this.updateCountdown(nowMs);

    const settling = this.width.animating || this.height.animating || this.radius.animating;
    // Port (performance): the shape springing, the greeting or the drop need
    // every display frame; the mascot alone (breathing, working) is stepped at 60.
    this.fullRate = settling || !this.botCx.settled || !this.botCy.settled || !this.botSize.settled ||
      greetingActive || UploadSeq.isActive || viewAnimating;
    const busy = State.mode === "hidden"
      ? settling
      : settling ||
        !this.botCx.settled || !this.botCy.settled || !this.botSize.settled ||
        greetingActive || this.engine.busy || UploadSeq.isActive || viewAnimating ||
        // Port: Robo never stands still (he blinks, glances, hops).
        (this.robot !== null && Robo.isRobo()) ||
        // Port: the compacting loop (and the chat's bar) while Claude Code compacts.
        Compaction.anyRunning() ||
        // Port: minis froze mid-animation once the mascot himself went still
        // (upstream's page gets mousemoves that keep its loop up).
        miniBotsBusy() ||
        // Port: a timed expression (the slap's squint, 0.8 s) ends inside step();
        // stopping first froze it on screen until the next pointer event. The
        // webview gets a mousemove for nearly every frame; the notch does not.
        (!!this.engine.eyeOverride && isFinite(this.engine.eyeOverrideUntil));

    if (!busy) {
      this.running = false;
      Sound.idle();
    }
    return busy;
  }

  lastDt = 0;
  /** Port: whether the open island wants every display frame (see frame()). */
  fullRate = true;
  /** Eye direction from the shell (bar the mascot), or null for upstream's own. */
  lookOverride: { x: number; y: number } | null = null;
  /**
   * Port (performance): whether the mascot follows the pointer at the moment
   * (the shell polls the cursor for the bar only then). Robo follows it only
   * idle, listening, happy or speaking (lib/robot/tv/sim.ts `follows`); not
   * asleep, at work or thinking. The mascot's eyes always do.
   */
  wantsPointer(): boolean {
    if (!this.robot || !Robo.isRobo()) return true;
    const s = this.robot.sim.state;
    return s === "idle" || s === "listening" || s === "happy" || s === "speaking";
  }

  private updateBotTargets() {
    const p = botPosition(State.mode, State.view, this.height.value, State.uploadProgress);
    this.botCx.target = p.cx;
    this.botCy.target = p.cy;
    // Port: the grown finished popup keeps the mascot where the card had him.
    if (State.mode === "expanded" && State.view === "finished" && this.finishedHeight > 0) {
      this.botCy.target = 101;
      // His ask: Robo a little lower there: half his antenna's height (the
      // head is centred where the mascot's body is; the antenna reads as higher).
      if (this.robot && Robo.isRobo()) {
        const f = this.robot.frame;
        this.botCy.target += this.robot.look.antenna ? (ANTENNA_UNITS / 2) * f.unit : 4;
      }
    }
    // Port (his ask): there is no upload page to chase the cursor on, so on the
    // chat page the mascot himself goes to sit under the file being dragged, kept
    // inside the island; the drop (or leaving) sends him home on his springs.
    if (State.fileDragOver && State.mode === "expanded" && State.view === "prompt") {
      const r = p.diameter / 2 + 6;
      const m = State.mouseInIsland;
      if (m.x > -5000) {
        this.botCx.target = Math.max(r, Math.min(this.width.value - r, m.x));
        this.botCy.target = Math.max(r, Math.min(this.height.value - r, m.y + p.diameter * 0.28));
      }
    }
    this.botSize.target = p.diameter / 0.6;

    const greetingActive = State.mode === "expanded" && State.view === "greeting";
    const away = State.mascotOnDesktop;
    this.bot.visible = p.opacity > 0 && !greetingActive && !this.uploadActive && !away;

    if (State.mode === "expanded" && State.view !== "uploading" && !greetingActive && !this.uploadActive && !away) {
      const d = p.diameter;
      this.glow = {
        x: this.botCx.value - d * 1.1,
        y: this.botCy.value - d * 1.1,
        d: d * 2.2,
        color: glowColor(State.effectiveState),
        opacity: botGlowOpacity(State.effectiveState),
      };
    } else {
      this.glow = null;
    }
  }

  /** The mascot's canvas rect (drawBot's style.left/top/width/height). */
  private placeBot() {
    const size = this.botSize.value;
    const w = Math.max(1, Math.round(size));
    const hCss = w + BOT_OVERHANG;
    const wCss = w + BOT_SIDE * 2;
    this.bot.size = w;
    this.bot.w = wCss;
    this.bot.h = hCss;
    this.bot.left = this.botCx.value - wCss / 2;
    this.bot.top = this.botCy.value - BOT_OVERHANG / 2 - hCss / 2;
  }

  /**
   * The engine half of upstream drawBot(): sets it up for this frame and
   * steps it. Run once per frame from frame() (where upstream draws), so any
   * number of canvases (the notch tab, the bar) can draw the same the mascot.
   */
  /** Port (his ask): Robo, the second mascot (lib/robot), while Settings choose him. */
  robot: Robot | null = null;
  /** When Robo last had a reason to be awake (work, the pointer near, a click). */
  private roboAwakeAt = performance.now();
  private prepareRobot(dt: number) {
    if (!Robo.isRobo()) {
      this.robot = null;
      return;
    }
    if (!this.robot) this.robot = new Robot(Robo.mainLook(), Math.max(20, this.bot.size), 0.37);
    const r = this.robot;
    r.setLook(Robo.mainLook());
    // Port (his ask): talking only while the answer's text is coming in; a
    // tool or more thinking in the same turn takes his face back.
    const ch = chat();
    const speaking = State.mode === "expanded" && ch.speaking();
    // The chat's "thinking" override lasts the whole turn: while a tool runs
    // or a card waits, Robo shows that rather than thinking.
    let botState = State.effectiveState;
    let botTask = State.stateOverride ? null : State.focusTask;
    if (State.stateOverride === "thinking" && ch.sending) {
      const pid = ch.pagePill();
      const pill = pid ? State.tasks.find((x) => x.id === pid) : undefined;
      // A card waiting: listening. A tool running: working (or searching).
      // Between tools the pill still says "working": he goes back to thinking.
      if (pill && (pill.state === "approval" || pill.state === "question" || (pill.state === "working" && ch.toolRunning()))) {
        botState = pill.state;
        botTask = pill;
      }
    }
    // (Dizzy holds his error face its whole 3.3 s: a chat answering kept
    // resetting the override, and he went straight back to his working face.)
    const state = performance.now() < this.dizzyUntil ? "error"
      : Robo.robotState(botState, speaking, botTask);
    // The head follows the pointer (the bar's look when the shell sets one).
    const lo = this.lookOverride;
    const rect = this.islandRect();
    const m = State.mouse;
    const rel = m.x > -5000 ? { x: m.x - (rect.x + this.botCx.value), y: m.y - this.botCy.value } : null;
    if (lo) r.look_at({ x: lo.x * 240, y: -lo.y * 180 });
    else r.look_at(rel);
    // His ask: idle long enough, he falls asleep (the desktop mascot's rule:
    // two minutes without an agent at work, the pointer not close); the
    // pointer coming near, a click or any work wakes him.
    const now = performance.now();
    const near = rel !== null && Math.hypot(rel.x, rel.y) < ROBO_SLEEP_NEAR;
    if (state !== "idle" || near) this.roboAwakeAt = now;
    r.setState(state === "idle" && now - this.roboAwakeAt > ROBO_SLEEP_AFTER * 1000 ? "sleeping" : state);
    // His ask: a file over the island opens the slot in his head.
    r.setOpen(State.fileDragOver);
    if (State.fileDragOver) this.roboAwakeAt = now;
    r.update(dt);
  }

  /** Port (his ask): Claude Code compacting: the mascot's loop (lib/compaction-anim.ts). */
  private wasCompacting = false;
  private prepareCompacting() {
    const on = Compaction.anyRunning();
    if (on && !this.wasCompacting) PersonalOnly.compactReset();
    this.wasCompacting = on;
    (this.engine as unknown as { __ambCompact?: boolean }).__ambCompact = on && AmbxstMascot.isAmbxst(this.engine as never);
    if (this.robot) {
      if (on) this.robot.sim.held = "compacting";
      else if (this.robot.sim.held === "compacting") this.robot.sim.held = null;
    } else if (on && !AmbxstMascot.isAmbxst(this.engine as never)) {
      // (the Coucou mascot's loop: a no-op in the public build, whose Axenide reads __ambCompact.)
      PersonalOnly.compactStep(this.engine as never);
    }
  }

  private prepareBot(dt: number) {
    this.prepareRobot(dt);
    this.prepareCompacting();
    const focus = State.focusTask;
    // Port (his ask): a chat in front wears its own colour (lib/looks.ts);
    // the main bot Settings' default one, if any.
    const frontConv = Looks.frontConv();
    const mainColor = !frontConv && focus?.id === State.mainPillId ? Looks.bodyHex(null, "") : "";
    this.engine.bodyColor = planCardOpen()
      ? hexToRGB(openPlanColor())
      : frontConv ? hexToRGB(Looks.bodyHex(frontConv, focus!.color))
      : mainColor ? hexToRGB(mainColor)
      : focus?.isIntegration || (focus as { helperOf?: string } | null)?.helperOf
        // Port: a helper wears its pill's colour too, like an integration.
        ? hexToRGB(focus!.color)
        : null;
    // Port: and its badge is a helper's (its parent's colour), as on its mini.
    this.helperBadge = (focus as { helperOf?: string } | null)?.helperOf ? hexToRGB(HELPER_BADGE) : null;
    this.engine.particleOverhang = BOT_OVERHANG;
    // The bar's mascot looks from where he is drawn (set by the shell while the
    // island is not open); upstream's island-relative look otherwise.
    const lo = this.lookOverride;
    this.engine.lookX = lo ? lo.x : this.lookX();
    this.engine.lookY = lo ? lo.y : this.lookY();
    if (this.engine.morph > 0.3) {
      this.engine.slotHTarget = State.fileDragOver ? 0.2 : 0;
    } else {
      this.engine.slotHTarget = 0;
      if (this.engine.morph < 0.05) {
        this.engine.slotH = 0;
        this.engine.slotHVel = 0;
      }
    }
    const inWardrobe = State.mode === "expanded" && State.view === "wardrobe";
    const mainFocused = State.focusId == null || State.focusId === State.mainPillId;
    // Port (his ask): a chat in front wears its own outfit.
    const showOutfit = mainFocused || !!frontConv || State.mode !== "expanded" || inWardrobe;
    const outfit = State.wardrobePreview ?? this.seasons.get(parseOutfit(frontConv ? Looks.outfitOf(frontConv) : State.settings.mascotOutfit));
    this.engine.setOutfit(showOutfit ? outfit : "none", !inWardrobe);
    // Port (his ask): music from any player (lib/media.ts), no music pill
    // needed: in the open island he dances too, on its home, while the pill in
    // front has nothing going on (an idle or finished session).
    const front = State.focusTask;
    const calm = !front || front.state === "idle" || front.state === "finished";
    this.engine.setDancing(islandDances({
      music: State.spotifyPlaying,
      state: State.effectiveState,
      mode: State.mode,
      view: State.view,
      focusId: State.spotifyPlaying && calm ? SPOTIFY_ID : front?.id,
    }));
    this.engine.update(dt);
  }

  /**
   * The drawing half of upstream drawBot(): the mascot into `ctx` (a CtxWrap whose
   * origin is the canvas' top-left, already cleared), `w` = body box (the
   * island's botSize), canvas `w + 2·BOT_SIDE` × `w + BOT_OVERHANG`.
   */
  drawBot(ctx: CanvasRenderingContext2D, w = this.bot.size) {
    const hCss = w + BOT_OVERHANG;
    // Port (his ask): Robo instead of the Coucou mascot, his head where the mascot's body sits.
    if (this.robot && Robo.isRobo()) {
      this.robot.setBox(w);
      // (His head on the mascot's body centre: the box's middle, 0.018 w below.)
      this.robot.drawAt(ctx, BOT_SIDE, hCss - w + w * 0.018);
      return;
    }
    ctx.save();
    ctx.translate(BOT_SIDE, 0);
    this.engine.applyDance(ctx, w, hCss);
    this.engine.draw(ctx, w, hCss);
    ctx.restore();
  }

  private lookX(): number {
    const rect = this.islandRect();
    const botScreenX = rect.x + this.botCx.value;
    return Math.tanh((State.mouse.x - botScreenX) / 260);
  }

  private lookY(): number {
    return -Math.tanh((State.mouse.y - this.botCy.value) / 200);
  }

  private updateCountdown(nowMs: number) {
    const dueAt = this.fsm.homeCollapseDueAt;
    if (State.mode !== "expanded" || State.isPinned || dueAt == null) {
      this.countdownW = 0;
      return;
    }
    const autoClose = this.fsm.homeToPetitDelay;
    const windowS = Math.min(10, autoClose * 0.6);
    const remaining = (dueAt - nowMs) / 1000;
    this.countdownW = remaining < windowS ? Math.max(0, clamp(remaining / windowS, 0, 1) * 160) : 0;
  }

  /** syncDom() without the DOM: the bits of state it derives. */
  private sync() {
    const expanded = State.mode === "expanded";
    const greetingActive = expanded && State.view === "greeting";
    const live = expanded && !greetingActive;
    this.content.opacity = live ? 1 : 0;
    this.content.interactive = live && !this.uploadActive;
    this.content.headerInteractive = live;

    if (this.greetingShown && !greetingActive) this.greeting.leave();
    this.greetingShown = greetingActive;
    if (State.wardrobePreview && !(expanded && State.view === "wardrobe")) State.wardrobePreview = null;
    // The wardrobe is the Coucou mascot's: switching to Robo with it open closes it.
    if (expanded && State.view === "wardrobe" && !Robo.hasWardrobe()) this.setView(State.defaultView());

    if (this.lastSyncedView !== State.view) {
      const wasChat = this.lastSyncedView === "prompt";
      this.lastSyncedView = State.view;
      if (State.view === "prompt") {
        void Bridge.focusWindow(true);
        window.setTimeout(() => this.host.viewFocus("prompt"), 120);
      } else if (wasChat) {
        void Bridge.focusWindow(false);
      }
    }

    const w = this.width.value;
    this.miniGrid.left = w - 40 - 14.5;
    this.miniGrid.top = this.height.value / 2 - 14.5;
    this.miniGrid.visible = State.mode === "compact";

    syncMiniBotStates(State.tasks);
    this.engine.setState(State.effectiveState);
  }

  applySettings() {
    Sound.setEnabled(State.settings.soundEnabled);
    Sound.setVolume(State.settings.soundVolume);
    this.fsm.homeToPetitDelay = State.settings.autoCloseInterval;
    this.fsm.openOnHover = State.settings.openOnHover;
    State.notify();
  }

  get chatHeight() {
    return chatPromptHeight(State.chatHistory.length);
  }
}

export { EXPANDED_W, PANEL_W };
