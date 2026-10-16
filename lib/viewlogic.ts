import { invoke } from "@tauri-apps/api/core";
import { island } from "./main";
// The decisions upstream's DOM view builders make, without the DOM, for the
// QML views to render. Each function cites the upstream code it mirrors.

import { State, type AgentTask } from "@coucou/core/state";
import { Bridge } from "@coucou/core/bridge";
import { isComingSoon, pillDefinition } from "@coucou/core/pills";
import { refreshHookPills } from "@coucou/island/integrations";
import { t } from "@coucou/i18n/i18n";

export { hasSessionTicker } from "@coucou/views/views";
export { idleStatus, timeAgo } from "@coucou/views/integrations";

const OPEN_URLS: Record<string, string> = {
  integration_resend: "https://resend.com/emails",
  integration_vercel: "https://vercel.com/dashboard",
  integration_github: "https://github.com",
  integration_stripe: "https://dashboard.stripe.com/payments",
  integration_notion: "https://notion.so",
  integration_calcom: "https://app.cal.com/bookings",
};

export interface LinkAction { label: string; color: string; run: () => void }

/** views/integrations.ts idleCard(): the link buttons under the status line. */
export function idleActions(task: AgentTask, openSettings: () => void): LinkAction[] {
  // Port (his call): before any session has reported, Claude Code's card has
  // nothing to open or refresh; IntegrationCard shows a hint instead.
  if (task.id === "integration_claude" && !task.sessionId) return [];
  const info = State.integrations[task.id];
  const configured = info?.configured ?? false;
  const def = pillDefinition(task.id);
  const out: LinkAction[] = [];
  if (task.id === "integration_claude") {
    // Port: Claude Code in a terminal, not VS Code (his setup has no VS Code).
    out.push({ label: t("Open {name}", { name: "Claude Code" }), color: `${task.color}b3`, run: () => { void invoke("open_claude_code", { path: task.sessionCwd ?? null }); island?.collapse(); } });
  } else if (task.id === "agent_claude-desktop") {
    out.push({ label: t("Open Claude"), color: `${task.color}d9`, run: () => void Bridge.openClaudeDesktop() });
  } else if (task.id === "integration_n8n") {
    out.push({ label: t("Open {name}", { name: "n8n" }), color: `${task.color}d9`, run: () => void Bridge.openN8n() });
  } else if (OPEN_URLS[task.id]) {
    out.push({ label: t("Open {name}", { name: task.name }), color: `${task.color}d9`, run: () => void Bridge.openUrl(OPEN_URLS[task.id]) });
  }
  const hookPill = def?.connect.kind === "hooks";
  if (isComingSoon(task.id) || def?.connect.kind === "none") {
    // Nothing to set up, and nothing to refresh.
  } else if (configured && (hookPill || def?.category !== "ai")) {
    out.push({
      label: t("Refresh"), color: `${task.color}d9`,
      run: () => void (hookPill ? refreshHookPills() : Bridge.refreshIntegration(task.id)),
    });
  } else if (!configured) {
    out.push({ label: t("Settings…"), color: "#8e939c", run: openSettings });
  }
  return out;
}
