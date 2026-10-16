// The DOM-free parts of Coucou's Settings window (upstream windows/src/settings/
// main.ts, agents.ts, colors.ts, parts.ts) for settings/RoboSettingsPage.qml.
// Upstream keeps its tables and strings in module-private constants and decides
// inline in the DOM builders; both are mirrored here 1:1, citing where. The
// phone link (phone.ts) is not ported.

import {
  Bridge, onEvent, type AgentHookStatus, type HookPreview, type HookStatus, type ShortcutsReport,
} from "@coucou/core/bridge";
import { CUSTOM_SERVER_KEY, providerDef, urlExposure } from "@coucou/core/providers";
import {
  ISLAND_SHORTCUTS, SHORTCUTS, SHORTCUT_TEXT, activeKeys, displayKeys, duplicates, effective,
  recordPress, type Binding, type KeyPress,
} from "@coucou/core/shortcuts";
import { DEFAULT_SETTINGS, type Settings } from "@coucou/core/state";
import { SOUND_NAMES } from "@coucou/core/sound";
import {
  MAX_DECLARED, PILL_CATEGORIES, availablePills, chooseMainPill, isComingSoon, mainPillChoices,
  sanitizeDeclared, toggleDeclared, type PillDefinition,
} from "@coucou/core/pills";
import { PILL_PALETTE, pillColor, withPillColor } from "@coucou/core/pill-colors";
import {
  LANGUAGES, N_, isRtl, onLanguageChange, resolveLanguage, setLanguage, systemLanguages, t, tn,
} from "@coucou/i18n/i18n";

export { onEvent, recordPress, displayKeys, PILL_PALETTE, LANGUAGES, isRtl, onLanguageChange, SOUND_NAMES };

/** main.ts:28-30 — where secrets.rs keeps the keys on this OS. */
export const KEY_STORE = typeof navigator !== "undefined" && (navigator.userAgent ?? "").includes("Windows")
  ? "Windows Credential Manager"
  : "Secret Service (GNOME Keyring, KWallet)";

/** main.ts:783 */
export const MAX_ACTIVE = MAX_DECLARED;

/** Errors as upstream prints them: `String(err)` without the "Error: " prefix. */
export function errorText(err: unknown): string {
  return String(err).replace(/^Error:\s*/, "");
}

/** parts.ts renderDiff: one line per diff line, classed add / del / ctx. */
export function diffLines(text: string): { cls: "add" | "del" | "ctx"; text: string }[] {
  return String(text ?? "").split("\n").map((line) => ({
    cls: line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx",
    text: line,
  }));
}

// ── Boot and render() data (main.ts:1294-1357) ────────────────────────────────

export async function boot(): Promise<{ settings: Settings; version: string }> {
  let settings: Settings = { ...DEFAULT_SETTINGS };
  let version = "";
  const b = await Bridge.boot();
  if (b) {
    settings = { ...settings, ...b.settings };
    version = b.version;
  }
  setLanguage(resolveLanguage(settings.language, systemLanguages()));
  return { settings, version };
}

/** main.ts:1260 applyLanguage */
export function applyLanguage(settings: Settings) {
  setLanguage(resolveLanguage(settings.language, systemLanguages()));
}

export interface RenderData {
  status: HookStatus;
  agents: AgentHookStatus[] | null;
  hasKey: boolean;
  shortcutReport: ShortcutsReport | null;
  present: Record<string, boolean>;
  connected: Record<string, boolean>;
  chatKeys: Record<string, boolean>;
  customKey: boolean;
  /** The sanitized declared pills, to merge into the settings (main.ts:1338). */
  declared: { mainPill: string; activeIntegrations: string[] };
}

/** main.ts:1321-1357 render(): reads what the sections show. */
export async function gather(settings: Settings): Promise<RenderData> {
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, planRelayInstalled: false, settingsPath: "", hookPath: "", hookReady: false,
  };
  const agents = await Bridge.agentHooksList();
  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
  const shortcutReport = await Bridge.shortcutsStatus();
  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;
  const declared = sanitizeDeclared(settings);
  const connected: Record<string, boolean> = { ...((await Bridge.agentHooksStatus()) ?? {}) };
  for (const def of availablePills()) {
    if (def.connect.kind === "key") {
      connected[def.id] = present[def.connect.key] ?? (await Bridge.secretPresent(def.connect.key)) ?? false;
    }
  }
  const chatKeys: Record<string, boolean> = {};
  for (const def of CLOUD) {
    const key = providerDef(def.id).key!;
    chatKeys[key] = (await Bridge.secretPresent(key)) ?? false;
  }
  const customKey = (await Bridge.secretPresent(CUSTOM_SERVER_KEY)) ?? false;
  return { status, agents, hasKey, shortcutReport, present, connected, chatKeys, customKey, declared: { ...declared } };
}

/** main.ts:1346-1351 keyChanged: a chat key was saved or removed. */
export function keyChanged(connected: Record<string, boolean>, key: string, on: boolean) {
  for (const def of availablePills()) {
    if (def.connect.kind === "key" && def.connect.key === key) connected[def.id] = on;
  }
}

/** main.ts:1310-1315: the local models section redraws only when these change. */
export function localKey(s: Settings): string {
  return `${s.chatProvider}|${s.ollamaUrl}|${s.lmstudioUrl}|${s.customUrl}`;
}

// ── Reviewing a change to someone else's file (main.ts:61-153, agents.ts) ────

export interface ChangeView {
  install: boolean;
  preview: () => Promise<HookPreview | null>;
  apply: (fingerprint: string) => Promise<string | null>;
  /** The hint above the diff. */
  intro: string;
  backupText: (backup: string) => string;
  confirmText: string;
  /** "primary" when installing, else "danger". */
  confirmKind: "primary" | "danger";
  doneText: (backup: string) => string;
  failedText: (err: unknown) => string;
  cancelText: string;
  backText: string;
}

const settingsBackup = (backup: string) => backup
  ? t("Backup → {path}", { path: backup })
  : t("No settings.json yet — nothing to back up.");

/** HOOKS_CHANGE, main.ts:73-83 */
export function hooksChange(install: boolean): ChangeView {
  return {
    install,
    preview: () => Bridge.hooksPreview(install),
    apply: (fp) => Bridge.hooksApply(install, fp),
    intro: install
      ? t("This is exactly what will change in your settings.json. Your own hooks are left untouched.")
      : t("This removes Robo's entries only. Your own hooks are left untouched."),
    backupText: settingsBackup,
    confirmText: install ? t("Back up and write") : t("Back up and remove"),
    confirmKind: install ? "primary" : "danger",
    doneText: (backup) => backup
      ? t("Done. Previous settings saved as {backup}. Open a new Claude Code session to pick the hooks up.", { backup })
      : t("Done. Open a new Claude Code session to pick the hooks up."),
    failedText: (err) => t("Could not write: {error}", { error: String(err) }),
    cancelText: t("Cancel"),
    backText: t("Back"),
  };
}

/** STATUS_LINE_CHANGE, main.ts:85-95 */
export function statusLineChange(install: boolean): ChangeView {
  return {
    install,
    preview: () => Bridge.statusLinePreview(install),
    apply: (fp) => Bridge.statusLineApply(install, fp),
    intro: install
      ? t("This is exactly what will change: only the status line. If you already have one it keeps working, Robo's relay runs it for you.")
      : t("This puts your previous status line back, or removes the entry if there was none."),
    backupText: settingsBackup,
    confirmText: install ? t("Back up and write") : t("Back up and remove"),
    confirmKind: install ? "primary" : "danger",
    doneText: (backup) => backup
      ? t("Done. Previous settings saved as {backup}. The numbers appear after the next reply of a Claude Code session.", { backup })
      : t("Done. The numbers appear after the next reply of a Claude Code session."),
    failedText: (err) => t("Could not write: {error}", { error: String(err) }),
    cancelText: t("Cancel"),
    backText: t("Back"),
  };
}

/** agents.ts showPreview + TEXT (agents.ts:11-37, 98-138). */
export function agentChange(status: AgentHookStatus, install: boolean): ChangeView {
  return {
    install,
    preview: () => Bridge.agentHooksPreview(status.id, install),
    apply: (fp) => Bridge.agentHooksApply(status.id, install, fp),
    intro: install
      ? t("This is exactly what changes for {name}. Nothing else is touched.", { name: status.name })
      : t("This removes Robo's entries only. Everything else stays."),
    backupText: (to) => (to ? t("Backup → {path}", { path: to }) : t("No existing file — nothing to back up.")),
    confirmText: install ? t("Back up and write") : t("Back up and remove"),
    confirmKind: install ? "primary" : "danger",
    doneText: (backups) => {
      const note = install ? status.note : "";
      const saved = backups
        ? t("Done. Previous version saved as {paths}.", { paths: backups.split("\n").join(", ") })
        : t("Done.");
      return `${saved} ${note}`;
    },
    failedText: (err) => t("Could not write: {error}", { error: errorText(err) }),
    cancelText: t("Cancel"),
    backText: t("Back"),
  };
}

/** agents.ts TEXT, the parts drawn outside a review. */
export const AGENT_TEXT = {
  get title() { return t("Agents"); },
  get intro() {
    return t("Show other coding agents in the island. Robo adds its entries to each agent's own config: you see the exact change and where the backup goes before anything is written, and uninstalling removes only what Robo added.");
  },
  get none() { return t("Robo could not list the agents."); },
  get approvals() { return t("Sessions, and Allow / Deny from the island"); },
  get displayOnly() { return t("Sessions — approvals stay in the agent"); },
  get install() { return t("Install…"); },
  get reinstall() { return t("Reinstall…"); },
  get uninstall() { return t("Uninstall…"); },
  get relayMissing() { return t("The relay isn't installed yet. Restart Robo."); },
};

// ── Claude Code section (main.ts:157-230) ─────────────────────────────────────

export const CLAUDE_TEXT = {
  hint: (installed: boolean) => installed
    ? t("Robo is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there.")
    : t("Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing."),
  get relay() { return t("Relay"); },
  get relayWarn() { return t("ambxst-robo-hook.exe is not in place yet. Restart Robo; if it still fails, build it with `cargo build -p ambxst-robo-hook`."); },
  install: (installed: boolean) => installed ? t("Reinstall hooks…") : t("Install hooks…"),
  get relayTitle() { return t("The relay isn't installed yet."); },
  get uninstall() { return t("Uninstall hooks…"); },
};

// ── Plan usage section (main.ts:240-320) ──────────────────────────────────────

export const PLAN_SETTINGS_TEXT = {
  get title() { return t("Plan usage"); },
  get claude() { return t("Shows your Claude plan usage (5-hour and weekly limits) in the island's header. Robo adds a status line relay in ~/.claude/settings.json. If you already have a status line, it keeps working as before. Pro and Max plans only."); },
  get claudeCli() { return t("The numbers come from the Claude Code command-line tool. The Claude desktop app does not report them, so the gauge stays empty if you only use the desktop app."); },
  get showClaude() { return t("Show in notch"); },
  get codex() { return t("Shows your Codex plan usage (weekly limit and free resets left) in the island's header. Robo asks the Codex CLI (codex app-server) when the pill shows; nothing is installed. Codex must be signed in with ChatGPT."); },
  get showCodex() { return t("Show Codex plan in the notch"); },
  get relay() { return t("Relay"); },
  relayState: (on: boolean) => on ? t("installed") : t("not installed"),
  get uninstallRelay() { return t("Uninstall relay…"); },
  get installRelay() { return t("Install relay…"); },
};

// ── Claude API section (main.ts:324-403) ──────────────────────────────────────

export const MODELS: [string, string][] = [
  ["claude-opus-5", "Claude Opus 5"],
  ["claude-sonnet-5", "Claude Sonnet 5"],
  ["claude-haiku-4-5", "Claude Haiku 4.5"],
];

/** The model select's options: the three, plus a saved model that isn't one of them. */
export function modelOptions(current: string): { value: string; text: string }[] {
  const out = MODELS.map(([value, text]) => ({ value, text }));
  if (!MODELS.some(([id]) => id === current)) out.push({ value: current, text: current });
  return out;
}

export const API_TEXT = {
  state: (present: boolean) => present
    ? t("Key saved in the {store}.", { store: KEY_STORE })
    : t("No key yet — the chat needs one."),
  placeholder: (present: boolean) => present ? `••••••••••••  ${t("(stored)")}` : "sk-ant-...",
  get save() { return t("Save key"); },
  get remove() { return t("Remove"); },
  get saved() { return t("Saved. It never touches disk."); },
  get removed() { return t("Key removed."); },
  couldNotSave: (err: unknown) => t("Could not save: {error}", { error: String(err) }),
  couldNotRemove: (err: unknown) => t("Could not remove: {error}", { error: String(err) }),
  get apiKey() { return t("API key"); },
  get model() { return t("Model"); },
};

// ── Chat providers and local models (main.ts:489-746) ─────────────────────────

export const CHAT_STRINGS = {
  get providersTitle() { return t("Chat providers"); },
  get providersHint() { return t("Chat with Google AI, OpenAI or OpenRouter instead of Claude: add a key here, then click the model name above the chat box to switch provider and model. Keys stay in the system keychain. These providers get no web search and no tools: they can answer, never act on this computer."); },
  get stored() { return `••••••••  ${t("(stored)")}`; },
  get save() { return t("Save"); },
  get remove() { return t("Remove"); },
  get localTitle() { return t("Local models"); },
  get localHint() { return t("Chat with a model you run yourself: Ollama or LM Studio (leave the address empty for the usual one on this computer), or any server that speaks the OpenAI API, such as vLLM or llama.cpp. Once connected, pick it above the chat box."); },
  get connect() { return t("Connect"); },
  get connecting() { return t("Connecting…"); },
  get disconnect() { return t("Disconnect"); },
  get useInChat() { return t("Use in chat"); },
  get inUse() { return t("In use"); },
  get keyOptional() { return t("API key (optional)"); },
  get localOnly() { return t("Nothing leaves your PC: the server runs on this computer."); },
  get remote() { return t("This address is another machine: what you ask is sent to it."); },
  get remoteHttp() { return t("This address is another machine, over plain http: what you ask travels unencrypted."); },
  get keyOverHttp() { return t("Warning: the key would be sent unencrypted (http://) to another machine. Use https://, or a server on this computer."); },
  get invalid() { return t("Not a valid http:// or https:// address."); },
  noModels: (name: string) => t("No models yet. Download one in {name} first.", { name }),
  models: (n: number) => tn("{count} model", "{count} models", n),
  keyFrom: (site: string) => t("Key from {site}", { site }),
};

export interface CloudDef {
  id: "google" | "openai" | "openrouter";
  name: string;
  placeholder: string;
  where: string;
}

export const CLOUD: CloudDef[] = [
  { id: "google", name: "Google AI", placeholder: "AIza…", where: "aistudio.google.com" },
  { id: "openai", name: "OpenAI", placeholder: "sk-…", where: "platform.openai.com" },
  { id: "openrouter", name: "OpenRouter", placeholder: "sk-or-…", where: "openrouter.ai/keys" },
];

/** CLOUD with what the rows need from the provider table. */
export function cloudRows(): (CloudDef & { key: string; accent: string })[] {
  return CLOUD.map((d) => {
    const p = providerDef(d.id);
    return { ...d, key: p.key!, accent: p.accent };
  });
}

export type LocalId = "ollama" | "lmstudio" | "custom";

export const LOCAL: Record<LocalId, { name: string; usual: string }> = {
  ollama: { name: "Ollama", usual: "http://127.0.0.1:11434" },
  lmstudio: { name: "LM Studio", usual: "http://127.0.0.1:1234" },
  custom: { name: N_("OpenAI-compatible"), usual: "" },
};

export { CUSTOM_SERVER_KEY };

/** The three server blocks with what they read from the provider table. */
export function localRows(): { id: LocalId; name: string; usual: string; accent: string; field: string; placeholder: string }[] {
  return (Object.keys(LOCAL) as LocalId[]).map((id) => {
    const p = providerDef(id);
    return {
      id, name: t(LOCAL[id].name), usual: LOCAL[id].usual, accent: p.accent, field: p.urlField!,
      placeholder: LOCAL[id].usual || "https://llm.example.com",
    };
  });
}

/** main.ts:609-622 exposureNotice → { cls: "hint" | "warn" | "err", text } or null. */
export function exposure(url: string, withKey: boolean): { cls: "hint" | "warn" | "err"; text: string } | null {
  switch (urlExposure(url)) {
    case "local":
      return { cls: "hint", text: CHAT_STRINGS.localOnly };
    case "remote":
      return { cls: "hint", text: CHAT_STRINGS.remote };
    case "remote-http":
      return withKey ? { cls: "warn", text: CHAT_STRINGS.keyOverHttp } : { cls: "hint", text: CHAT_STRINGS.remoteHttp };
    case "invalid":
      return url.trim() ? { cls: "err", text: CHAT_STRINGS.invalid } : null;
  }
  return null;
}

/**
 * main.ts:705-734, the Connect click past the UI: stores the custom key, asks
 * the server, and returns the settings to save, or the error to show.
 */
export async function connectLocal(
  settings: Settings, id: LocalId, url: string, key: string,
): Promise<{ ok: true; settings: Partial<Settings>; customKey: boolean } | { ok: false; error: string; customKey: boolean }> {
  const def = LOCAL[id];
  let customKey = false;
  try {
    if (id === "custom" && key.trim()) {
      await Bridge.localSetKey(url || def.usual, key.trim());
      customKey = true;
    }
    const server = await Bridge.localConnect(id, url);
    if (!server.models.length) return { ok: false, error: CHAT_STRINGS.noModels(t(def.name)), customKey };
    const field = providerDef(id).urlField!;
    const next: Partial<Settings> = { [field]: server.url } as Partial<Settings>;
    if (!server.models.includes(settings.chatModels[id] ?? "")) {
      next.chatModels = { ...settings.chatModels, [id]: server.models[0] };
    }
    return { ok: true, settings: next, customKey };
  } catch (err) {
    return { ok: false, error: errorText(err), customKey };
  }
}

/** main.ts:660-668 Disconnect. Returns the settings to save. */
export async function disconnectLocal(settings: Settings, id: LocalId): Promise<Partial<Settings>> {
  const field = providerDef(id).urlField!;
  const next: Partial<Settings> = { [field]: "" } as Partial<Settings>;
  if (settings.chatProvider === id) next.chatProvider = "anthropic";
  if (id === "custom") await Bridge.secretClear(CUSTOM_SERVER_KEY).catch(() => {});
  return next;
}

// ── Active pills (main.ts:412-485) ────────────────────────────────────────────

export const PILLS_TEXT = {
  get title() { return t("Active pills"); },
  get intro() { return t("Choose the tools you use. Robo only shows what you declare here."); },
  slots: (used: number) => t("{used}/{max} slots in use — the main tool doesn't take one.", { used, max: MAX_ACTIVE }),
  get mainTool() { return t("Main tool"); },
  get main() { return t("Main"); },
  get color() { return t("Color"); },
  get reset() { return t("Default"); },
};

export function mainOptions(): { value: string; text: string }[] {
  return mainPillChoices().map((d) => ({ value: d.id, text: d.name }));
}

/** main.ts:426-432 — why a pill would show nothing yet. */
function pillHint(def: PillDefinition, settings: Settings, connected: Record<string, boolean>): string | null {
  if (isComingSoon(def.id)) return t("Coming soon");
  if (def.connect.kind === "hooks" && !connected[def.id]) return t("Hooks not installed");
  if (def.connect.kind === "key" && !connected[def.id]) return t("Key not configured");
  if (def.connect.kind === "server" && !(settings as unknown as Record<string, unknown>)[def.connect.field]) return t("Not connected");
  return null;
}

export interface PillRow {
  id: string;
  name: string;
  /** Catalog colour (the colour dot's `def.color`). */
  color: string;
  isMain: boolean;
  on: boolean;
  full: boolean;
  state: string;
}

/** main.ts:434-472 — the groups and rows of the section, services left out. */
export function pillGroups(settings: Settings, connected: Record<string, boolean>): { title: string; rows: PillRow[] }[] {
  const groups: { title: string; rows: PillRow[] }[] = [];
  for (const cat of PILL_CATEGORIES) {
    if (cat.id === "service") continue;
    const pills = availablePills().filter((p) => p.category === cat.id);
    if (pills.length === 0) continue;
    groups.push({
      title: t(cat.title),
      rows: pills.map((def) => {
        const isMain = def.id === settings.mainPill;
        const on = settings.activeIntegrations.includes(def.id);
        const full = !isMain && !on && settings.activeIntegrations.length >= MAX_ACTIVE;
        return {
          id: def.id, name: def.name, color: def.color, isMain, on, full,
          state: isMain ? t("Main") : pillHint(def, settings, connected) ?? "",
        };
      }),
    });
  }
  return groups;
}

/** main.ts:416-422: the main tool select. Returns the settings to store, or null. */
export function chooseMain(settings: Settings, id: string): { mainPill: string; activeIntegrations: string[] } | null {
  const next = chooseMainPill(settings, id);
  return next ? { mainPill: next.mainPill, activeIntegrations: next.activeIntegrations } : null;
}

/** main.ts:450-455: a pill row's switch. */
export function togglePill(settings: Settings, id: string): string[] | null {
  return toggleDeclared(settings, id);
}

// ── Colour dot and palette (colors.ts) ────────────────────────────────────────

export function currentColor(id: string, catalog: string, colors: unknown): string {
  return pillColor(id, catalog, colors);
}

/** colors.ts:60-77 — the swatches, which one is on, and whether "Default" shows. */
export function paletteFor(id: string, catalog: string, colors: unknown): { swatches: { hex: string; on: boolean }[]; reset: boolean } {
  const now = pillColor(id, catalog, colors);
  return {
    swatches: PILL_PALETTE.map((hex) => ({ hex, on: hex === now })),
    reset: now !== pillColor(id, catalog, null),
  };
}

/** colors.ts choose(): the next `pillColors`. `hex` null = back to the catalog colour. */
export function pickColor(colors: unknown, id: string, hex: string | null, catalog: string): Record<string, string> {
  return withPillColor(colors, id, hex, catalog);
}

// ── Integrations (main.ts:750-874) ────────────────────────────────────────────

export interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
  hint?: string;
}

export const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: N_("Secret key"), placeholder: "sk_live_…", secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [{ key: "github-token", label: N_("Token"), placeholder: "ghp_…", secret: true }],
    hint: N_("Classic token with the repo scope, or fine-grained with read access to Pull requests, Commit statuses and Actions.") },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF",
    fields: [{ key: "vercel-token", label: N_("Token"), placeholder: "…", secret: true }] },
  { id: "integration_n8n", name: "n8n", color: "#F29B38",
    fields: [
      { key: "n8n-url", label: N_("Instance URL"), placeholder: "https://n8n.example.com", secret: false },
      { key: "n8n-api-key", label: N_("API key"), placeholder: "…", secret: true },
    ] },
  { id: "integration_resend", name: "Resend", color: "#22C55E",
    fields: [{ key: "resend-api-key", label: N_("API key"), placeholder: "re_…", secret: true }] },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C",
    fields: [{ key: "notion-api-key", label: N_("Integration token"), placeholder: "ntn_…", secret: true }] },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A",
    fields: [{ key: "calcom-api-key", label: N_("API key"), placeholder: "cal_…", secret: true }] },
  { id: "integration_spotify", name: "Spotify", color: "#1DB954", fields: [] },
];

/** main.ts:803-804 — only the services this build offers, labels translated. */
export function integrationRows(): IntegrationDef[] {
  const offered = new Set(availablePills().map((p) => p.id));
  return INTEGRATIONS.filter((d) => offered.has(d.id)).map((d) => ({
    ...d,
    fields: d.fields.map((f) => ({ ...f, label: t(f.label) })),
    hint: d.hint ? t(d.hint) : undefined,
  }));
}

export const INTEGRATIONS_TEXT = {
  get title() { return t("Integrations"); },
  // Port: whichever mascot shows (lib/mascots.ts): "your mascot".
  note: (used: number) => t("Pick up to {max} pills to show next to your mascot — {used}/{max} in use. Keys are stored in the {store}, never on disk.", { max: MAX_ACTIVE, used, store: KEY_STORE }),
  get save() { return t("Save"); },
  get notInstalled() { return t("Not installed"); },
};

/** main.ts:807-816: an integration's switch. Returns the next list, or null when full. */
export function toggleIntegration(settings: Settings, id: string): string[] | null {
  if (settings.activeIntegrations.includes(id)) return settings.activeIntegrations.filter((x) => x !== id);
  if (settings.activeIntegrations.length >= MAX_ACTIVE) return null;
  return [...settings.activeIntegrations, id];
}

// ── General (main.ts:878-989, 1207-1249) ──────────────────────────────────────

export const GENERAL_TEXT = {
  get title() { return t("General"); },
  get sound() { return t("Sound"); },
  custom: (n: number) => (n > 0 ? t("{0} custom", { 0: n }) : ""),
  get openFolder() { return t("Open sounds folder"); },
  get reload() { return t("Reload sounds"); },
  get soundsHint() { return t("Drop a file named like one of your mascot's sounds (finish.wav, approval.mp3, greet.m4a…) in the sounds folder to replace it, then Reload."); },
  get openOnHover() { return t("Open on hover"); },
  /** Port only: the desktop mascot stays on the overlay layer when he sits. */
  get keepMascotAbove() { return t("Keep your mascot above fullscreen apps"); },
  get keepMascotAboveHint() { return t("Your mascot stays visible on the desktop over fullscreen windows (games, videos)."); },
  /** Port only: state colours from the shell's matugen palette. */
  get matugenColors() { return t("Theme-matched process colours"); },
  get matugenColorsHint() { return t("Your mascot's working, thinking, approval… colours and their glow follow your wallpaper palette instead of the default ones."); },
  get hoverHint() { return t("Hovering the island opens it; it folds again shortly after the pointer leaves. Click inside to keep it open."); },
  get autoClose() { return t("Auto-close"); },
  get autoCloseUnit() { return t("seconds after you leave the island"); },
  get livesOn() { return t("Island lives on"); },
  get mainDisplay() { return t("Main display"); },
  get underCursor() { return t("Display under the cursor"); },
  get autostart() { return t("Launch at startup"); },
  get language() { return t("Language"); },
  get system() { return t("System"); },
  get recapLabel() { return t("Weekly recap"); },
  get recapKeep() { return t("Keep a history of my coding sessions"); },
  get recapClear() { return t("Clear history"); },
  get recapCleared() { return t("History cleared."); },
  get recapAbout() { return t("Counts and project names only — never commands, files or prompts. Kept on this computer for 12 weeks."); },
  get footer() { return t("No telemetry. Network requests only go to the services you configure yourself."); },
};

/** main.ts:908 — the auto-close field's value once committed. */
export function clampAutoClose(raw: string): number {
  return Math.max(5, Math.min(120, Number(raw) || 15));
}

/** main.ts:919-933 — the option the screen select shows for the saved value. */
export function pickScreen(saved: string, keys: string[]): string {
  const [place, name] = saved.split("|");
  const v =
    keys.find((k) => k === saved) ??
    (saved.startsWith("at:") ? keys.find((k) => k.split("|")[0] === place) : undefined) ??
    (name ? keys.find((k) => k.split("|")[1] === name) : undefined) ??
    saved;
  return v || "primary";
}

/** main.ts:978-989 — "System" + the ten languages, each in its own script. */
export function languageOptions(): { value: string; text: string }[] {
  return [{ value: "", text: t("System") }, ...LANGUAGES.map(({ code, name }) => ({ value: code, text: name }))];
}

export function languageValue(settings: Settings): string {
  return LANGUAGES.some((l) => l.code === settings.language) ? settings.language : "";
}

// ── Shortcuts (main.ts:993-1204) ──────────────────────────────────────────────

export const SHORTCUTS_UI = {
  get title() { return t("Shortcuts"); },
  get hint() { return t("Work from any app. Click a shortcut to change it, then press the new keys — Esc cancels, Backspace removes it."); },
  get global() { return t("From anywhere"); },
  get island() { return t("In the open island"); },
  get recording() { return t("Press keys…"); },
  get none() { return t("None"); },
  get reset() { return t("Reset to defaults"); },
  get inUse() { return t("In use by another app"); },
  get duplicate() { return t("Used twice"); },
  get invalid() { return t("Not a valid shortcut"); },
  get unavailable() { return t("Not available"); },
  types: (ch: string) => t("Types “{char}”", { char: ch }),
  typesNote: (keys: string, ch: string) =>
    t("{keys} types “{char}” on your keyboard, so it can't be a shortcut. Pick another key.", { keys, char: ch }),
  get needsModifier() { return t("Hold Ctrl, Alt or the Windows key with it."); },
  get unsupportedKey() { return t("That key can't be used in a shortcut."); },
  get wayland() {
    return t("Your Wayland desktop doesn't let apps listen for keys outside their own windows. Add the shortcuts in your system's keyboard settings instead, with these commands:");
  },
  get noDisplay() { return t("No display server was found, so global shortcuts are off."); },
  get portalPending() { return t("Asking your desktop to register the shortcuts. It may show its own window to confirm them."); },
  get portalActive() { return t("These shortcuts are registered with your desktop. It may ask you to confirm them or to pick other keys; when it says which keys it uses, they show next to each shortcut."); },
  get portalFallback() { return t("If one doesn't work, you can also add it in your system's keyboard settings with these commands:"); },
  desktopKeys: (keys: string) => t("Desktop: {keys}", { keys }),
  get refused() { return t("Not set by your desktop"); },
  // Ambxst: ambxst-robo reports `blocked: "shell"`; the shell binds the keys
  // in Hyprland (RoboShell.applyShortcuts). Not upstream strings.
  get shell() { return t("Bound by the shell"); },
  shellNote: (command: string) => t("Ambxst binds these keys in Hyprland: each one runs {command} <action>.", { command }),
};

export interface ShortcutRow {
  id: string;
  name: string;
  keys: string;
  keycap: string;
  enabled: boolean;
  tag: { cls: "" | "warn" | "err"; text: string } | null;
}

/** main.ts:1040-1054 tagFor, with ambxst-robo's "shell" report. */
function tagFor(id: string, dups: Set<string>, report: ShortcutsReport | null): ShortcutRow["tag"] {
  if (dups.has(id)) return { cls: "err", text: SHORTCUTS_UI.duplicate };
  const st = report?.actions.find((a) => a.id === id);
  switch (st?.status as string | undefined) {
    case "inUse": return { cls: "warn", text: SHORTCUTS_UI.inUse };
    case "duplicate": return { cls: "err", text: SHORTCUTS_UI.duplicate };
    case "invalid": return { cls: "err", text: SHORTCUTS_UI.invalid };
    case "typesCharacter": return { cls: "warn", text: SHORTCUTS_UI.types(st!.typed ?? "?") };
    case "unsupported":
      return { cls: "", text: report?.blocked === "shell" ? SHORTCUTS_UI.shell : SHORTCUTS_UI.unavailable };
    case "refused": return { cls: "warn", text: SHORTCUTS_UI.refused };
    case "active": return st!.trigger ? { cls: "", text: SHORTCUTS_UI.desktopKeys(st!.trigger) } : null;
    default: return null;
  }
}

/** main.ts:1111-1131 — the "From anywhere" rows. */
export function shortcutRows(settings: Settings, report: ShortcutsReport | null): ShortcutRow[] {
  const dups = duplicates(activeKeys(settings.shortcuts));
  const rows: ShortcutRow[] = [];
  for (const d of SHORTCUTS) {
    if (!d.ported) continue;
    const binding = effective(d, settings.shortcuts);
    rows.push({
      id: d.id,
      name: t(SHORTCUT_TEXT[d.id]),
      keys: binding.keys,
      keycap: binding.keys ? displayKeys(binding.keys) : SHORTCUTS_UI.none,
      enabled: binding.enabled,
      tag: binding.enabled ? tagFor(d.id, dups, report) : null,
    });
  }
  return rows;
}

/** main.ts:1133-1157 — the note under the list: { notice, hint, commands }. */
export function shortcutNote(report: ShortcutsReport | null): { notice: { cls: string; text: string } | null; hint: string; commands: string[] } {
  const commands = (command: string) => SHORTCUTS.filter((d) => d.ported).map((d) => `${command} ${d.id}`);
  if (report?.portal) {
    const active = report.portal === "active";
    return {
      notice: { cls: active ? "ok" : "", text: active ? SHORTCUTS_UI.portalActive : SHORTCUTS_UI.portalPending },
      hint: SHORTCUTS_UI.portalFallback,
      commands: commands(report.command),
    };
  }
  if (report?.blocked === "wayland") return { notice: { cls: "warn", text: SHORTCUTS_UI.wayland }, hint: "", commands: commands(report.command) };
  if (report?.blocked === "shell") return { notice: { cls: "ok", text: SHORTCUTS_UI.shellNote(report.command.replace(/^.*\//, "")) }, hint: "", commands: [] };
  if (report?.blocked) return { notice: { cls: "warn", text: SHORTCUTS_UI.noDisplay }, hint: "", commands: [] };
  return { notice: null, hint: "", commands: [] };
}

/** main.ts:1063-1095 — a key press while recording → what to do. */
export function recordKey(e: KeyPress, binding: Binding): {
  kind: "pending" | "store" | "feedback" | "finish";
  binding?: Binding;
  feedback?: string;
  /** typesCharacter finishes AND shows a note. */
  finish?: boolean;
} {
  const result = recordPress(e);
  switch (result.kind) {
    case "pending": return { kind: "pending" };
    case "keys": return { kind: "store", binding: { keys: result.keys, enabled: true } };
    case "clear": return { kind: "store", binding: { keys: "", enabled: binding.enabled } };
    case "typesCharacter":
      return { kind: "feedback", finish: true, feedback: SHORTCUTS_UI.typesNote(displayKeys(result.keys), result.typed) };
    case "needsModifier": return { kind: "feedback", feedback: SHORTCUTS_UI.needsModifier };
    case "unsupported": return { kind: "feedback", feedback: SHORTCUTS_UI.unsupportedKey };
    case "cancel": return { kind: "finish" };
  }
  return { kind: "pending" };
}

/** main.ts:1160-1166 — "In the open island", read-only. */
export function islandShortcuts(): { keys: string; text: string }[] {
  return ISLAND_SHORTCUTS.map((r) => ({ keys: r.keys, text: t(r.description) }));
}

/** The window's title (main.ts:1266). */
export function windowTitle(): string {
  return t("Settings — Ambxst Robo");
}

// ── Port (his ask): one box for every key ─────────────────────────────────────
// Integrations take their keys from one "Paste a key" box: most services stamp
// a recognisable prefix on theirs, so the key says where it goes; the rest ask.

/** Where a pasted key goes: the secret it is stored as, and the pill it lights. */
export interface KeyTarget { kind: "integration" | "ai"; id: string; name: string; secret: string }

const KEY_RULES: [RegExp, KeyTarget][] = [
  [/^(ghp_|gho_|ghu_|ghs_|github_pat_)/, { kind: "integration", id: "integration_github", name: "GitHub", secret: "github-token" }],
  [/^(sk_live_|sk_test_|rk_live_|rk_test_)/, { kind: "integration", id: "integration_stripe", name: "Stripe", secret: "stripe-api-key" }],
  [/^re_[A-Za-z0-9]/, { kind: "integration", id: "integration_resend", name: "Resend", secret: "resend-api-key" }],
  [/^(ntn_|secret_)/, { kind: "integration", id: "integration_notion", name: "Notion", secret: "notion-api-key" }],
  [/^cal_(live|test)_/, { kind: "integration", id: "integration_calcom", name: "Cal.com", secret: "calcom-api-key" }],
  // Order matters: Anthropic's and OpenRouter's keys start with "sk-" too.
  [/^sk-ant-/, { kind: "ai", id: "anthropic", name: "Anthropic", secret: "anthropic-api-key" }],
  [/^sk-or-/, { kind: "ai", id: "openrouter", name: "OpenRouter", secret: "openrouter-api-key" }],
  [/^sk-(proj-|svcacct-|[A-Za-z0-9]{20,})/, { kind: "ai", id: "openai", name: "OpenAI", secret: "openai-api-key" }],
  [/^AIza[0-9A-Za-z_-]{20,}/, { kind: "ai", id: "google", name: "Google AI", secret: "google-api-key" }],
];

/** The service a key belongs to, from its prefix; null when it doesn't say. */
export function detectKey(raw: string): KeyTarget | null {
  const key = raw.trim();
  for (const [re, target] of KEY_RULES) if (re.test(key)) return target;
  return null;
}

/** What a key without a telling prefix can be for (the box's "which service?"). */
export function unprefixedTargets(): KeyTarget[] {
  return [
    { kind: "integration", id: "integration_vercel", name: "Vercel", secret: "vercel-token" },
    { kind: "integration", id: "integration_n8n", name: "n8n", secret: "n8n-api-key" },
    { kind: "integration", id: "integration_github", name: "GitHub", secret: "github-token" },
    { kind: "integration", id: "integration_stripe", name: "Stripe", secret: "stripe-api-key" },
    { kind: "integration", id: "integration_notion", name: "Notion", secret: "notion-api-key" },
    { kind: "integration", id: "integration_calcom", name: "Cal.com", secret: "calcom-api-key" },
    { kind: "integration", id: "integration_resend", name: "Resend", secret: "resend-api-key" },
  ];
}
