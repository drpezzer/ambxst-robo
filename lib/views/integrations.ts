// views/integrations.ts renderIntegrationCard() and views/github.ts, without the
// DOM: which card the overview's left card shows for an integration pill, and
// the rows / labels / colours each card draws. IntegrationCard.qml renders it.

import { State, type AgentTask } from "@coucou/core/state";
import { Bridge } from "@coucou/core/bridge";
import {
  CI_COLORS, GH_STRINGS, GRID_WEEKS, activityHeader, actionsUrl, ciWord, contributionColor,
  formatCount, lastDays, lastWeeks, mainCISummary, myPRsValue, profileUrl, readActivity, readPulse,
  readStats, safeGitHubUrl, sectionTitle, shortRepo, weekColumn, worstCI,
  type ContributionDay, type GitHubActivity, type GitHubStats, type GitHubPR, type GitHubRepoCI, type GitHubSection,
} from "@coucou/core/github";
import { hasIntegrationData, timeAgo } from "@coucou/views/integrations";
import { ICONS } from "@coucou/views/icons";
import { language, t } from "@coucou/i18n/i18n";

export { hasIntegrationData };

function get(id: string): Record<string, unknown> {
  return (State.integrations[id]?.data ?? {}) as Record<string, unknown>;
}

function arr(id: string, key: string): Record<string, unknown>[] {
  const v = get(id)[key];
  return Array.isArray(v) ? (v as Record<string, unknown>[]) : [];
}

/**
 * renderIntegrationCard's dispatch: "idle", "n8n", "n8nDetail", "vercel",
 * "vercelDetail", "githubPulse", "githubDetail", "github", "resend", "stripe",
 * "notion", "calcom".
 */
export function cardKind(task: AgentTask, detailOpen: boolean): string {
  if (task.id === "integration_n8n") {
    const hasActivity = task.steps.length > 0 && (task.state === "finished" || task.state === "error");
    if (!hasActivity) return "idle";
    return detailOpen ? "n8nDetail" : "n8n";
  }
  if (task.id === "integration_vercel" && hasIntegrationData(task.id)) {
    return detailOpen ? "vercelDetail" : "vercel";
  }
  if (!hasIntegrationData(task.id)) return "idle";
  if (task.id === "integration_github" && readPulse(get(task.id))) {
    return detailOpen ? "githubDetail" : "githubPulse";
  }
  switch (task.id) {
    case "integration_resend": return "resend";
    case "integration_github": return "github";
    case "integration_stripe": return "stripe";
    case "integration_notion": return "notion";
    case "integration_calcom": return "calcom";
    default: return "idle";
  }
}

// ── Vercel ────────────────────────────────────────────────────────────────────

export function vercelRows(): { name: string; ago: string; accent: string }[] {
  return arr("integration_vercel", "deployments").slice(0, 3).map((d) => ({
    name: String(d.projectName ?? ""),
    ago: timeAgo(d.createdAt),
    accent: d.state === "READY" ? "#22C55E" : "#F4505E",
  }));
}

export function vercelDetail() {
  const d = arr("integration_vercel", "deployments")[0] ?? {};
  const success = d.state === "READY";
  return {
    name: String(d.projectName ?? t("Deployment")),
    accent: success ? "#22C55E" : "#F4505E",
    status: success ? t("Ready") : d.state === "CANCELED" ? t("Canceled") : t("Error"),
    commit: d.commitMessage ? String(d.commitMessage) : "",
    branch: d.branch ? String(d.branch) : "",
    ago: t("{time} ago", { time: timeAgo(d.createdAt) }),
    url: d.url ? String(d.url) : "",
    open: () => void Bridge.openUrl(`https://${d.url}`),
  };
}

// ── Resend ────────────────────────────────────────────────────────────────────

export function resend() {
  const total = get("integration_resend").total;
  const rows = arr("integration_resend", "emails").slice(0, 3).map((e, i) => {
    const to = Array.isArray(e.to) ? String(e.to[0] ?? "?") : "?";
    return {
      name: to.split("@")[0],
      ago: timeAgo(e.createdAt),
      accent: e.lastEvent === "delivered" ? "#22C55E" : "#F4505E",
      sub: i === 0 && e.subject ? String(e.subject) : "",
    };
  });
  return { total: total != null ? String(total) : "", hasTotal: total != null, rows };
}

// ── GitHub (no pulse) ─────────────────────────────────────────────────────────

export function githubStats() {
  const d = get("integration_github");
  const stars = Number(d.totalStars ?? 0);
  const repos = Number(d.totalRepos ?? 0);
  return {
    stats: [
      { icon: ICONS.star, color: "#F5A524", label: t("Total stars"), value: stars >= 1000 ? `${(stars / 1000).toFixed(1)}k` : String(stars) },
      { icon: ICONS.stack, color: "#6B7079", label: t("Repositories"), value: String(repos) },
    ],
  };
}

// ── Stripe ────────────────────────────────────────────────────────────────────

export function stripe() {
  const d = get("integration_stripe");
  return {
    balance: (Number(d.balance ?? 0) / 100).toFixed(2),
    currency: String(d.currency ?? "eur").toUpperCase(),
    rows: arr("integration_stripe", "payments").map((p) => ({
      name: String(p.description ?? t("Payment")),
      amount: `+${(Number(p.amount ?? 0) / 100).toFixed(2)}`,
      ago: timeAgo(p.createdAt),
      accent: p.status === "succeeded" ? "#22C55E" : "#F4505E",
    })),
  };
}

// ── Notion ────────────────────────────────────────────────────────────────────

export function notion() {
  return arr("integration_notion", "pages").slice(0, 3).map((p) => ({
    emoji: p.emoji ? String(p.emoji) : "",
    title: String(p.title ?? t("Untitled")),
    ago: timeAgo(p.lastEditedAt),
    open: () => {
      if (typeof p.url === "string") void Bridge.openUrl(p.url);
    },
  }));
}

// ── Cal.com ───────────────────────────────────────────────────────────────────

const pad2 = (n: number) => String(n).padStart(2, "0");

/** toLocaleDateString(language(), { day, month: "2-digit" }) + toLocaleTimeString(…, { hour, minute: "2-digit" }). */
function bookingWhen(when: Date): string {
  const lang = language();
  try {
    // V4's toLocale*String ignore their options; the Intl shim (lib/intl-shim.js)
    // only covers i18n.ts's calls: use the English form below then.
    if (typeof Intl !== "undefined" && Intl.DateTimeFormat && !(Intl as unknown as { __shim?: boolean }).__shim) {
      const day = when.toLocaleDateString(lang, { day: "2-digit", month: "2-digit" });
      const time = when.toLocaleTimeString(lang, { hour: "2-digit", minute: "2-digit" });
      return `${day} ${time}`;
    }
  } catch {
    // No Intl in this engine: the English form below.
  }
  const h = when.getHours();
  const day = `${pad2(when.getMonth() + 1)}/${pad2(when.getDate())}`;
  const time = lang === "en"
    ? `${pad2(h % 12 || 12)}:${pad2(when.getMinutes())} ${h < 12 ? "AM" : "PM"}`
    : `${pad2(h)}:${pad2(when.getMinutes())}`;
  return `${day} ${time}`;
}

export function calcom() {
  const bookings = arr("integration_calcom", "bookings")
    .slice()
    .sort((a, b) => new Date(String(a.start)).getTime() - new Date(String(b.start)).getTime());
  return {
    empty: bookings.length === 0 ? t("No calls scheduled") : "",
    rows: bookings.slice(0, 3).map((b) => ({
      time: bookingWhen(new Date(String(b.start))),
      name: String(b.title ?? t("Meeting")),
    })),
  };
}

// ── n8n ───────────────────────────────────────────────────────────────────────

export function n8n(task: AgentTask) {
  const success = task.state === "finished";
  return {
    accent: success ? "#22C55E" : "#F4505E",
    name: task.steps[0] ?? t("Workflow"),
    badge: success ? t("Success") : t("Failed"),
    detail: task.steps[1] ?? "",
    status: success ? t("Completed successfully.") : t("No error details available."),
  };
}

// ── GitHub pulse (views/github.ts) ────────────────────────────────────────────

/** Which list the detail view shows; kept across re-renders of the card. */
let openSection: GitHubSection = "myPRs";

export function section(): GitHubSection {
  return openSection;
}

/** githubPulseCard's show(): pick the list, ask Rust for fresh data, open the detail. */
export function showSection(s: GitHubSection, openDetail: () => void) {
  openSection = s;
  void Bridge.githubRefresh(s === "activity" ? "activity" : "pulse");
  openDetail();
}

function open(url: string) {
  const safe = safeGitHubUrl(url);
  if (safe) void Bridge.openUrl(safe);
}

export function githubPulse() {
  const d = get("integration_github");
  const pulse = readPulse(d)!;
  const stats = readStats(d);
  const activity = readActivity(d);
  const main = mainCISummary(pulse.mainCI);
  const reviews = pulse.toReview.length;
  return {
    title: GH_STRINGS.title,
    spark: !!(stats || activity),
    stars: stats ? `★ ${formatCount(stats.totalStars)}` : "",
    mini: activity ? lastDays(activity, 7).map((day) => contributionColor(day.level)) : [],
    overview: GH_STRINGS.overview,
    stats: [
      { icon: ICONS.pull, stroke: 2.2, evenOdd: false, color: CI_COLORS[worstCI(pulse.myPRs.map((p) => p.ci))],
        label: GH_STRINGS.myPRs, value: myPRsValue(pulse.myPRs), section: "myPRs" },
      { icon: ICONS.eye, stroke: 2.2, evenOdd: false, color: reviews > 0 ? "#8AB4F8" : "#6B7079",
        label: GH_STRINGS.toReview, value: String(reviews), section: "toReview" },
      { icon: main.failing ? ICONS.octagonX : ICONS.seal, stroke: 0, evenOdd: true, color: main.color,
        label: GH_STRINGS.mainCI, value: main.value, section: "mainCI" },
    ],
  };
}

export interface GhRow {
  dot: string;
  dotOpacity: number;
  /** A 5 px gap instead of the CI dot (the To review list). */
  gap: boolean;
  ref: string;
  title: string;
  draft: string;
  word: string;
  wordColor: string;
  open: () => void;
}

function prRow(pr: GitHubPR, showCI: boolean): GhRow {
  return {
    dot: CI_COLORS[pr.ci], dotOpacity: pr.ci === "unknown" ? 0 : 1, gap: !showCI,
    ref: `${shortRepo(pr.repo)}#${pr.number}`, title: pr.title,
    draft: pr.isDraft ? GH_STRINGS.draft : "", word: "", wordColor: "",
    open: () => open(pr.url),
  };
}

function repoRow(repo: GitHubRepoCI): GhRow {
  return {
    dot: CI_COLORS[repo.ci], dotOpacity: repo.ci === "unknown" ? 0 : 1, gap: false,
    ref: shortRepo(repo.repo), title: repo.branch, draft: "",
    word: ciWord(repo.ci) ?? "", wordColor: CI_COLORS[repo.ci],
    open: () => open(actionsUrl(repo.url)),
  };
}

/** totalLabel(): 1234 → "1,234". V4's toLocaleString ignores the locale, so by hand. */
const grouped = (n: number) => String(Math.trunc(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");

/** core/github.ts activityHeader, with the year's total grouped as upstream's totalLabel does. */
function activityTitle(activity: GitHubActivity | null, stats: GitHubStats | null, picked: ContributionDay | null): string {
  if (picked || !activity) return activityHeader(activity, stats, picked);
  const total = GH_STRINGS.pastYear(grouped(activity.total));
  return stats ? `${total} · ${GH_STRINGS.repos(stats.totalRepos)}` : total;
}

/** githubDetail(): the list of the open section, or the contribution grid. */
export function githubDetail() {
  const d = get("integration_github");
  const pulse = readPulse(d)!;
  const stats = readStats(d);
  const activity = readActivity(d);
  if (openSection === "activity") {
    const weeks = activity
      ? lastWeeks(activity, GRID_WEEKS).map((week) =>
          weekColumn(week).map((day) => (day ? { day, color: contributionColor(day.level) } : null)))
      : [];
    return {
      section: "activity", title: GH_STRINGS.activity, rows: [] as GhRow[], fade: false,
      empty: activity ? "" : GH_STRINGS.loading, hasActivity: !!activity, weeks,
      header: (picked: ContributionDay | null) => activityTitle(activity, stats, picked),
      openProfile: () => open(profileUrl(pulse.login)),
    };
  }
  const rows =
    openSection === "mainCI"
      ? pulse.mainCI.map(repoRow)
      : (openSection === "myPRs" ? pulse.myPRs : pulse.toReview).map((pr) => prRow(pr, openSection === "myPRs"));
  return {
    section: openSection, title: sectionTitle(openSection), rows, fade: rows.length > 3,
    empty: rows.length === 0 ? GH_STRINGS.nothingHere : "", hasActivity: false, weeks: [],
    header: () => "", openProfile: () => {},
  };
}
