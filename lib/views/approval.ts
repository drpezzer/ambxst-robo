// The permission card and the question card (views/views.ts buildApproval,
// buildQuestion) without the DOM: what each shows and the question card's
// stepping, for ApprovalView.qml / QuestionView.qml to render.

import { State } from "@coucou/core/state";
import { lastTextStep } from "@coucou/core/diff";
import { N_, t } from "@coucou/i18n/i18n";
import { CHAT_PILL_ID, SKIP_QUESTION } from "../claudecode";

/** Port: the question card's own-answer field (like Claude Code's "Other"). */
export const OTHER_PLACEHOLDER = N_("Other…");

/** views.ts CLICK_GUARD_MS: a fresh permission card ignores clicks this long. */
export const CLICK_GUARD_MS = 600;

const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());

/** buildApproval(): the who label, the code line and the click guard. */
export class ApprovalCard {
  private shownFor: string | null = null;
  private shownAt = 0;

  /** sync(): call on every State change while the card exists. */
  sync(): { who: string; code: string } {
    const req = State.pendingApproval?.requestId ?? null;
    if (req !== this.shownFor) {
      this.shownFor = req;
      this.shownAt = now();
    }
    return {
      who: t("needs permission"),
      code: State.pendingApproval?.command || State.pendingApproval?.tool || "…",
    };
  }

  /** guarded(d): a click on Deny / Allow, ignored in the first 600 ms. */
  decide(d: "allow" | "deny", decide: (d: "allow" | "deny") => void): void {
    this.sync();
    if (now() - this.shownAt < CLICK_GUARD_MS) return;
    decide(d);
  }
}

/** Longest typed "Other…" answer, in characters (ambxst-robo / ambxst-robo-hook take up to 4000). */
export const OTHER_MAX = 2000;

export interface QuestionOptionModel { label: string; description: string; on: boolean }

export type QuestionModel =
  | { mode: "terminal"; who: string; title: string; tooltip: string; fold: boolean; terminalText: string }
  | {
      mode: "pick"; who: string; title: string; tooltip: string; fold: boolean;
      key: string; multi: boolean; options: QuestionOptionModel[]; doneOff: boolean;
      doneLabel: string; terminalLabel: string; otherPlaceholder: string;
    };

/** buildQuestion(): which question is on screen, what is picked, the answers so far. */
export class QuestionCard {
  private requestId = "";
  private index = 0;
  private answers: Record<string, string | string[]> = {};
  private picked = new Set<string>();

  sync(): QuestionModel {
    const questions = State.pendingApproval?.questions;
    // Only a request that is waiting can be folded away and come back.
    const fold = !!State.pendingApproval;
    // A question that arrived as a notification has nothing to pick from.
    if (!questions) {
      const task = State.focusTask;
      const title = (task && lastTextStep(task.steps)) ?? t("Claude needs an answer.");
      return {
        mode: "terminal", who: t("is asking a question"), title, tooltip: "", fold,
        terminalText: t("Answer it in your terminal."),
      };
    }
    if (State.pendingApproval!.requestId !== this.requestId) {
      this.requestId = State.pendingApproval!.requestId;
      this.index = 0;
      this.answers = {};
      this.picked = new Set();
    }
    const q = questions[Math.min(this.index, questions.length - 1)];
    const who = questions.length > 1
      ? t("is asking ({index} of {total})", { index: this.index + 1, total: questions.length })
      : t("is asking");
    return {
      mode: "pick", who, title: q.question, tooltip: q.question, fold,
      key: `${this.requestId}:${this.index}:${[...this.picked].join("|")}`,
      multi: q.multiSelect,
      options: q.options.map((o) => ({ label: o.label, description: o.description, on: this.picked.has(o.label) })),
      doneOff: this.picked.size === 0,
      doneLabel: t("Done"),
      otherPlaceholder: t(OTHER_PLACEHOLDER),
      // Port: the chat's own question has no terminal to go to; leaving it
      // unanswered tells Claude Code no answer came.
      terminalLabel: State.pendingApproval!.pillId === CHAT_PILL_ID ? t(SKIP_QUESTION) : t("Answer in terminal"),
    };
  }

  /** An option button was clicked: answers a single-select question, toggles a multi-select one. */
  pick(label: string, answer: (a: Record<string, string | string[]>) => void): void {
    const questions = State.pendingApproval?.questions;
    if (!questions) return;
    const q = questions[Math.min(this.index, questions.length - 1)];
    if (!q.multiSelect) {
      this.next(q.question, label, questions.length, answer);
      return;
    }
    if (this.picked.has(label)) this.picked.delete(label);
    else this.picked.add(label);
    State.notify();
  }

  /** "Done" on a multi-select question: nothing happens until something is picked. */
  done(answer: (a: Record<string, string | string[]>) => void): void {
    const questions = State.pendingApproval?.questions;
    if (!questions || this.picked.size === 0) return;
    const q = questions[Math.min(this.index, questions.length - 1)];
    this.next(q.question, [...this.picked], questions.length, answer);
  }

  /**
   * Port: the "Other…" field (Claude Code's own AskUserQuestion "Other"): the
   * typed text answers this question; on a pick-several question it joins the
   * picks. Blank text does nothing. ambxst-robo / ambxst-robo-hook accept it.
   */
  other(text: string, answer: (a: Record<string, string | string[]>) => void): boolean {
    const questions = State.pendingApproval?.questions;
    const typed = String(text ?? "").trim().slice(0, OTHER_MAX);
    if (!questions || !typed) return false;
    const q = questions[Math.min(this.index, questions.length - 1)];
    if (!q.multiSelect) {
      this.next(q.question, typed, questions.length, answer);
      return true;
    }
    const picks = [...this.picked];
    if (!picks.includes(typed)) picks.push(typed);
    this.next(q.question, picks, questions.length, answer);
    return true;
  }

  private next(question: string, value: string | string[], total: number, answer: (a: Record<string, string | string[]>) => void) {
    this.answers[question] = value;
    this.picked = new Set();
    this.index += 1;
    if (this.index >= total) answer(this.answers);
    else State.notify();
  }
}

// Upstream builds each view once and keeps it: the card's guard clock and the
// question card's progress outlive the QML view (which is only loaded while on screen).
export const approvalCard = new ApprovalCard();
export const questionCard = new QuestionCard();
