// Port-only chat provider: the user's own Claude Code CLI and subscription
// (ambxst-robo claude_code.rs). Upstream's providers.ts is left untouched: its
// exported PROVIDERS list is extended here at load, first in the picker. No
// key, no address: the CLI's login is what it needs.

import { PROVIDERS, type ProviderDef } from "@coucou/core/providers";
import { Bridge } from "@coucou/core/bridge";
import { State } from "@coucou/core/state";
import { N_ } from "@coucou/i18n/i18n";

export const CLAUDE_CODE_ID: string = "claudecode";
/** Credential store entry of the Anthropic key (claude.rs KEY). */
const ANTHROPIC_KEY = "anthropic-api-key";

export const CLAUDE_CODE: ProviderDef = {
  id: CLAUDE_CODE_ID as ProviderDef["id"],
  name: "Claude Code",
  accent: "#D97757",
  key: null,
  urlField: null,
  defaultModel: "claude-sonnet-5-5",
  prefer: "claude-sonnet-5-5",
};

/** The picker's labels for the exact ids claude_code.rs lists (MODELS). */
const MODEL_LABELS: Record<string, string> = {
  "claude-fable-5-1": "Claude Fable 5.1",
  "claude-opus-5-5": "Claude Opus 5.5",
  "claude-sonnet-5-5": "Claude Sonnet 5.5",
  "claude-haiku-4-5-20251001": "Claude Haiku 4.5",
};

/** Bare CLI aliases an earlier build saved, and the exact id each now is (claude_code.rs LEGACY_ALIASES). */
const LEGACY_ALIASES: Record<string, string> = {
  sonnet: "claude-sonnet-5-5",
  opus: "claude-opus-5-5",
  haiku: "claude-haiku-4-5-20251001",
  fable: "claude-fable-5-1",
};

/** The model's label, or the id itself. */
export function modelLabel(id: string): string {
  return MODEL_LABELS[id] ?? id;
}

/**
 * A saved bare alias ("sonnet") becomes its exact id, once, and is saved.
 * Returns true when the settings changed.
 */
export function migrateModel(): boolean {
  const saved = (State.settings.chatModels ?? {})[CLAUDE_CODE_ID];
  const id = saved ? LEGACY_ALIASES[saved.trim()] : undefined;
  if (!id) return false;
  State.settings = { ...State.settings, chatModels: { ...State.settings.chatModels, [CLAUDE_CODE_ID]: id } };
  void Bridge.saveSettings(State.settings);
  return true;
}

// ── What the chat's Claude Code runs may do (claude_code.rs ChatMode) ─────────

export type ChatModeId = "ask" | "readonly" | "edit" | "auto";
export const DEFAULT_CHAT_MODE: ChatModeId = "ask";

/** settings.json key (Settings.claude_code_chat_mode in ambxst-robo). */
const MODE_KEY = "claudeCodeChatMode";

export const CHAT_MODES: { id: ChatModeId; label: string; hint: string }[] = [
  {
    id: "ask",
    label: N_("Ask"),
    hint: N_("Anything that needs approval comes up here as Allow / Deny"),
  },
  {
    id: "readonly",
    label: N_("Read only"),
    hint: N_("Only reads files; anything else is refused"),
  },
  {
    id: "edit",
    label: N_("Edit files"),
    hint: N_("Edits files without asking; asks before the rest"),
  },
  {
    id: "auto",
    label: N_("Auto"),
    hint: N_("Claude Code's auto mode: a safety check approves routine actions and blocks risky ones"),
  },
];

/**
 * The pill the chat's own permission card comes up on (its dot and name head
 * the card: "● Chat needs permission"). Made for the card, gone when the reply
 * ends (views/chat.ts).
 */
export const CHAT_PILL_ID = "agent_robo-chat";
export const CHAT_PILL_NAME = N_("Chat");
/** The question card's way out for the chat's questions (no terminal to answer in). */
export const SKIP_QUESTION = N_("Skip");

/** The picker's heading above the modes. */
export const MODES_TITLE = N_("Permissions");

/** The chosen mode (anything unknown reads as the default, as ambxst-robo stores it). */
export function chatMode(): ChatModeId {
  const v = (State.settings as unknown as Record<string, unknown>)[MODE_KEY];
  return CHAT_MODES.some((m) => m.id === v) ? (v as ChatModeId) : DEFAULT_CHAT_MODE;
}

export function setChatMode(id: ChatModeId): void {
  if (!CHAT_MODES.some((m) => m.id === id)) return;
  State.settings = { ...State.settings, [MODE_KEY]: id } as typeof State.settings;
  void Bridge.saveSettings(State.settings);
}

/** The picker's status line while Claude Code is the chosen provider. */
export const SUBSCRIPTION_NOTE = N_("Uses your Claude Code subscription");

const list = PROVIDERS as ProviderDef[];
if (!list.some((p) => p.id === CLAUDE_CODE_ID)) list.unshift(CLAUDE_CODE);

let checked: Promise<void> | null = null;

/**
 * Claude Code becomes the chat's provider when none was chosen, or when the
 * choice is Anthropic without an Anthropic key (the stock default, which
 * could not answer). Any other explicit choice is kept. Checked once per start.
 */
export function ensureDefaultProvider(): Promise<void> {
  checked ??= (async () => {
    const current = State.settings.chatProvider as string;
    if (current && current !== "anthropic") return;
    let hasKey = false;
    try {
      hasKey = (await Bridge.secretPresent(ANTHROPIC_KEY)) === true;
    } catch {
      hasKey = false;
    }
    const now = State.settings.chatProvider as string;
    if (hasKey || (now && now !== "anthropic")) return;
    State.settings = { ...State.settings, chatProvider: CLAUDE_CODE_ID as never };
    void Bridge.saveSettings(State.settings);
    State.notify();
  })();
  return checked;
}
